/*
 * sync_project_with_scm.e
 */

/*
 * TODO: (chrisant) The file system scan takes a long time for large projects.
 * Either make the scan an interruptible state machine on idle, or move it to
 * a DLL (possibly on a background thread) to avoid the overhead cost of
 * updating editor buffer data structures.  My old PROJ macro implemented what
 * both sync_project_with_scm.e and enhproj.e do; perhaps I should combine
 * them in SlickEdit as I did in my old editor?  This was particularly
 * convenient because pressing <F5> in the open file dialog started scanning
 * the file system on a background thread.  In SlickEdit it will be a little
 * more complicated because once the file list is complete files need to be
 * updated in the project and new files need to be tagged, but tagging can't
 * happen in the background.
 *
 * TODO: (chrisant) There are phases where this macro makes SlickEdit
 * unresponsive without giving any visual feedback to the user.  I believe the
 * user should always know why the editor is unresponsive.
 *
 * TODO: (chrisant) Measure how long it takes SlickEdit to build the hash and
 * update the project file list.  Investigate if the instant-replace logic
 * from my old PROJ macro/DLL can be used somehow in SlickEdit.
 *
 * TODO: (chrisant) Right now it loops through projects, performing all phases
 * for each project.  Consider instead looping through phases, performing each
 * phase for all projects.
 */
#pragma option(pedantic, on)
#region Imports
#include "slick.sh"
#import "wkspace.e"
#import "main.e"
#import "projutil.e"
#import "stdprocs.e"
#import "dir.e"
#import "clipbd.e"
#import "tagform.e"
#import "put.e"
#import "makefile.e"

/**
 * Static variables.
 */
static bool s_fReloadIni = true;
static bool s_fGlobalIniLoaded = false;
static int s_idIni = -1;
static int s_isDebugging = 0;

definit()
{
   if(arg(1) != 'L')
      s_idIni = -1;
   s_fReloadIni = true;
}

/**
 * Structure that defines one directory to scan.
 * @see translate_wildcard_list
 */
struct DIRINFO
{
   bool fRecurse;    // Scan recursively.
   bool fExclude;    // "dir" is really a prefix to exclude.
   _str dir;            // Directory to scan.
   _str filespec;       // Optional wildcards (see translate_wildcard_list).
};

/**
 * Structure for keeping track of cumulative totals while updating projects.
 */
struct CUMULATIVETOTALS
{
   int cAdded;
   int cRemoved;
   int cTotal;
};

static void ini_discard()
{
   // Delete our temp view of the ini file, if we have one.
   if(s_idIni >= 0)
   {
      _delete_temp_view(s_idIni);
      s_idIni = -1;
   }
}

static void ini_get_aliases(_str (&aliases):[])
{
   aliases._makeempty();
   // First initialize the predefined set of aliases.
   aliases:['sources'] =
               '*.c;*.cc;*.cpp;*.cp;*.cxx;*.c++;':+
               '*.h;*.hh;*.hpp;*.hxx;*.i;*.inl;':+
               '*.cs;':+
               '*.rc;*.rc2;*.pp;*.csv;*.dlg;':+
               '*.idl;*.odl;':+
               '*.bat;*.cmd;*.btm;':+
               '*.pl;*.pm;':+
               '*.asm;*.inc;':+
               '*.bas;*.cls;':+
               '*.rcp;':+
               '*.lua;':+
               '*.txt;*.htm;*.html;*.xml;*.php;':+
               '*.def;*.ini;*.inf;':+
               'makefile;makefile.*;*.mak;sources;sources.*;dirs;':+
               'jamfile;jamrules;':+
               '*.mm*;*.ver;':+
               '';
   aliases:['headers'] =
               '*.h;*.hh;*.hpp;*.hxx;*.i;*.inl;':+
               '*.idl;*.odl;':+
               '*.asm;*.inc;':+
               '*.txt;*.htm;*.html;*.xml;*.php;':+
               '*.def;*.ini;*.inf;':+
               'makefile;makefile.*;*.mak;sources;sources.*;dirs;':+
               'jamfile;jamrules;':+
               '*.mm*;*.ver;':+
               '';
   aliases:['slick'] =
               '*.e;*.sh;':+
               '*.c;*.cpp;*.h;':+
               '*.java;':+
               '*.rc;':+
               '*.txt;*.htm;*.html;*.xml;*.php;':+
               '*.def;*.ini;*.inf;':+
               'makefile;makefile.*;*.mak;':+
               '*.mm*;*.ver;':+
               '';

   // Then read custom aliases from the ini file.
   int idOrig;
   save_selection(auto ss);
   get_window_id(idOrig);
   activate_window(s_idIni);
   top();
   _str line;
   _str alias;
   _str list;
   while(true)
   {
      _begin_line();

      // Search for next alias definition.
      if(0 != search('^[ \t]*\<?+\>[ \t]*=', 'ir'))
         break;

      // Add the alias definition to the list.
      get_line(line);
      parse line with . '<' alias '>' . '=' list;
      if(length(alias))
      {
         _str lcAlias = lowcase(alias);
         if(list == '')
         {
            // An empty alias line (before translation!) deletes the alias.
            if(aliases._indexin(lcAlias))
               aliases._deleteel(lcAlias);
         }
         else
         {
            // Expand any aliases within this alias definition.
            translate_wildcard_list(list, aliases);
            list = strip(list);
            if(!aliases._indexin(lcAlias))
               aliases:[lcAlias] = '';
            if(length(aliases:[lcAlias]) && last_char(aliases:[lcAlias]) != ';')
               aliases:[lcAlias] :+= ';';
            aliases:[lcAlias] :+= list;
         }
      }

      if(down() != 0)
         break;
   }

   activate_window(idOrig);
   restore_selection(ss);
}

/**
 * Update the file lists for the projects in the current workspace.  Only
 * projects in the "projects" array (near the top of this macro source file)
 * are updated.
 *
 * <ul>
 * <li>Use "ssync" to sync the current project.
 * <li>Use "ssync -a" to sync all projects in the current workspace.
 * <li>Use "ssync -v#" to set debug output level to #.
 * </ul>
 */
_command void ssync() name_info(','VSARG2_REQUIRES_PROJECT_SUPPORT)
{
   int beginTime = (int) _time('G');
   s_fReloadIni = true;

   s_isDebugging = 0;

   if(_workspace_filename == '')
   {
      message("No workspace open.");
      return;
   }

   // Get the list of projects to sync.
   int status;
   int ii;
   _str sOpts;
   _str sArgs = strip_options(arg(1), sOpts);
   _str arrayProjects[] = null;
   bool fUsageError = false;
   if(sOpts != '')
   {
      _str arrayOpts[] = null;
      split(sOpts, ' ', arrayOpts);
      for(ii = 0; ii < arrayOpts._length(); ii++)
      {
         if(arrayOpts[ii] == '-a')
         {
            status = _GetWorkspaceFiles(_workspace_filename,arrayProjects);
            if(status)
            {
               _message_box(nls("ssync: Unable to get projects from workspace '%s'.\n\n%s", _workspace_filename, get_message(status)));
               return;
            }
         }
         else if(substr(arrayOpts[ii], 1, 2) == '-v')
         {
            s_isDebugging = (int)substr(arrayOpts[ii], 3);
         }
         else
         {
            fUsageError = true;
         }
      }
   }
   if(length(sArgs))
   {
      fUsageError = true;
   }
   if(!arrayProjects._length())
   {
      if(_project_name != '')
         arrayProjects[0] = _project_name
   }
   if(fUsageError)
   {
      _message_box("ssync: Syntax error.\n\nUsage:  ssync [-a]\n\nThe -a flag syncs all projects in the workspace.\nOtherwise only syncs the current project.");
      return;
   }
   if(!arrayProjects._length())
   {
      message("No projects to sync.");
      return;
   }

   _str aliases:[];
   // Loop over the projects.
   _str filename = '';
   _str displayname = '';
   CUMULATIVETOTALS totals;
   totals.cAdded = 0;
   totals.cRemoved = 0;
   totals.cTotal = 0;
   for (ii = 0; ii < arrayProjects._length(); ii++)
   {
      filename = _AbsoluteToWorkspace(_strip_filename(arrayProjects[ii], 'E') :+ PRJ_FILE_EXT);
      displayname = GetProjectDisplayName(arrayProjects[ii]);

      message("Scanning project '"displayname"' ("ii+1"/"arrayProjects._length()")...");

      if (s_isDebugging)
         say("Scanning project '"filename"'...");

      ssync_project(filename, totals, aliases);
   }

   // Clean up
   ini_discard();

   int endTime = (int) _time('G');

   int interval = endTime - beginTime;
   int hours = interval/3600;
   interval = interval - hours*3600;
   int minutes = interval/60;
   int seconds = interval - minutes*60;

   // Report cumulative results.
   message("Ssync completed for ":+
           arrayProjects._length() " project(s)  /  files: " :+
           totals.cAdded " added, " :+
           totals.cRemoved " removed, " :+
           totals.cTotal " total. " :+
           hours " hours, " :+
           minutes " minutes, " :+
           seconds " seconds");
}

static void ssync_project(_str project, CUMULATIVETOTALS& totals, _str(&aliases):[])
{
   // Add the project's dir list.
   _str wksName = _strip_filename(_workspace_filename, 'PE');
   _str projName = _strip_filename(project, 'PE');
   DIRINFO dir_list[];
   if(!dinfo_get_project(dir_list, projName, wksName,project,aliases))
   {
      _message_box(nls("ssync: No dir list for project '%s'.", projName));
      return;
   }

   // Change to the project file's directory so relative paths can work.
   int status;
   _str old_cwd = getcwd();
   _str prj_root = _strip_filename(project, 'NE');
   if(prj_root != '')
   {
      status = chdir(prj_root, 1);
      if(status)
      {
         _message_box(nls("ssync: Could not change to directory '%s'.", prj_root));
         return;
      }
   }

   // Update the project file list.
   status = ssync_worker(project, dir_list, totals);
   if (status)
   {
      _message_box(nls("ssync: Error updating project '%s'.\n\n%s", project, get_message(status)));
   }

   // Restore the original working directory.
   if(prj_root != '' && old_cwd != '')
   {
      status = chdir(old_cwd, 1);
      if(status)
      {
         _message_box(nls("ssync: Could not change back to directory '%s'.", old_cwd));
         return;
      }
   }
}

void remove_files_from_project(_str project, _str filelist_remove)
{
    if(filelist_remove != "")
    {
       filelist_remove = strip(filelist_remove, 'B');

       int status = project_remove_filelist(project, filelist_remove);
       if(status != 0)
       {
          _message_box(nls("ssync: Warning: Unable to remove files from project.\n\n%s", get_message(status)));
       }
    }
}
/**
 * Updates the file list for the specified project.
 *
 * @param project       The project to update.
 * @param dir_list      The dir list to use to update the project file list.
 *
 * @return int          Returns status code (0 for success, else failure).
 */
static int ssync_worker(_str project, DIRINFO (&dir_list)[], CUMULATIVETOTALS& totals)
{
   // Get list of current project files.
   int projectfiles_list:[];
   ssync_getprojectfilelist(project, projectfiles_list);

   // Create our temporary view for insert_file_list().
   int filelist_view_id;
   int orig_view_id = _create_temp_view(filelist_view_id);
   fileman_mode();

   // Do an insert_file_list() for every dir_list + file_spec entry.
   //$ review: (chrisant) This can take a long time...!
   int ii;
   _str excludeCmd = "-exclude";
   for(ii = 0; ii < dir_list._length(); ii++)
   {
      DIRINFO dirInfo = dir_list[ii];  //$ review: (chrisant) Suspected perf degradation due to copy operation.

      // Exclude entries go in another array.
      if(dirInfo.fExclude)
      {
         excludeCmd = excludeCmd " " stranslate(dirInfo.dir, FILESEP, FILESEP2);
      }
   }

   for(ii = 0; ii < dir_list._length(); ii++)
   {
      DIRINFO dirInfo = dir_list[ii];  //$ review: (chrisant) Suspected perf degradation due to copy operation.

      // Exclude entries already handled previously
      if(dirInfo.fExclude)
      {
         continue;
      }

      // Split out file spec list into an array.
      _str file_specs[];
      split(stranslate(dirInfo.filespec, FILESEP, FILESEP2), ';', file_specs);

      // Insert file lists.
      int jj;
      _str cmd;
      _str dirAbsolute = _maybe_quote_filename(absolute(dirInfo.dir, _strip_filename(project, 'NE')));
      _maybe_append_filesep(dirAbsolute);
      cmd = (dirInfo.fRecurse ? "+t " : "");
      cmd = cmd dirAbsolute " -wc";
      for(jj = 0; jj < file_specs._length(); jj++)
      {
         cmd = cmd " " _maybe_quote_filename(file_specs[jj]);
      }
      cmd = cmd " " excludeCmd;

      if(s_isDebugging >= 2)
         say('list:    'cmd);

      insert_file_list("-v +a +p " cmd);
   }

   // Remove duplicate files.
   int file_list_hash:[];
   file_list_hash._makeempty();

   top();
   up();
   while(!down())
   {
      _str filename;

      get_line(filename);
      if(s_isDebugging >= 6)
         messageNwait('got "'filename'"');
      filename = stranslate(filename, FILESEP, FILESEP2);
      filename = strip(filename, 'B');
      if(_fpos_case != '')
      {
         filename = lowcase(filename);
      }

      if(projectfiles_list._indexin(filename))
      {
         // If this file is current in the project, set the projectfiles_list
         //  entry to 1 (so we don't remove it from the project) and then
         //  remove this entry from the temp buffer add list.
         projectfiles_list:[filename] = 1;

         delete_line();
         up();
      }
      else if(file_list_hash._indexin(filename) &&
         file_list_hash:[filename] != p_line)
      {
         // This is a new file and it's a duplicate so whack it.
         delete_line();
         up();
      }
      else
      {
         // New file: record the line number we first saw it at.
         file_list_hash:[filename] = p_line;
      }
   }

   // Create a list of files to remove from the project. Every hash entry
   //  in projectfiles_list[] that is a 0 should be removed.
   _str filename;
   _str filelist_remove = "";
   int files_removed = 0;
   for(filename._makeempty();;)
   {
      projectfiles_list._nextel(filename);
      if(filename._isempty())
         break;
      if(projectfiles_list:[filename] != 0)
         continue;

      if(s_isDebugging >= 1)
         say('remove:  "'filename'"');

      files_removed++;
      //$ PERF: (chrisant) String growth has exponential cost here unless
      // Slick-C is using geometric growth under the covers.  However, the
      // number of files removed should typically be small, so this may be
      // acceptable.
      filelist_remove = filelist_remove " " _maybe_quote_filename(filename);
      if ( (files_removed % 1000) == 999 )
      {
          // If too many files to remove, then filelist_remove was growing too
          // large and crashing SE, so remove 1000 files at a time.
          remove_files_from_project(project, filelist_remove);
          filelist_remove="";
      }
   }
   remove_files_from_project(project, filelist_remove);

   // Add the new list of files to our project.
   if(file_list_hash._length())
   {
      if(s_isDebugging >= 1)
      {
         _str line;
         filelist_view_id.top();
         do
         {
            filelist_view_id.get_line(line);
            if(line != '')
               say('add:     "'strip(line)'"');
         }
         while(!filelist_view_id.down());
      }

      tag_add_viewlist(_GetWorkspaceTagsFilename(), filelist_view_id, project);
   }
   else
   {
      _delete_temp_view(filelist_view_id);
   }

   int project_filecount = projectfiles_list._length() - files_removed + file_list_hash._length();

#if 0
   message("Ssync completed: " file_list_hash._length() " files added, " :+
           files_removed " files removed, " :+
           project_filecount " files total.");
#endif

   totals.cAdded += file_list_hash._length();
   totals.cRemoved += files_removed;
   totals.cTotal += project_filecount;

   activate_window(orig_view_id);
   return(0);
}

/**
 * Translates the specified <i>wildcard_list</i>, replacing aliases in angle
 * brackets as defined in the <i>aliases</i> array.
 */
static void translate_wildcard_list(_str& wildcard_list, _str (&aliases):[])
{
   _str list = wildcard_list;
   wildcard_list = '';

   if(length(list) == 0)
   {
      if(aliases._indexin('sources'))
         wildcard_list :+= aliases:['sources'];
   }
   else
   {
      do
      {
         parse list with auto a '<' auto b '>' auto c;

         if(length(a))
            wildcard_list :+= a;
         if(length(b))
         {
            if(aliases._indexin(lowcase(b)))
               wildcard_list :+= aliases:[lowcase(b)];
            else
               wildcard_list :+= '<' :+ b :+ '>';
         }

         list = c;
      }
      while(length(list) != 0);
   }
}

/**
 * Adds elements to the <i>dir_list</i> array.<br>
 * Assumes the current buffer is the ini file temp view, and that a project
 * section is marked.
 *
 * @see DIRINFO
 * @see translate_wildcard_list
 */
static void dinfo_add(DIRINFO (&dir_list)[], _str (&aliases):[])
{
   _begin_select();
   _begin_line();

   _str line;
   DIRINFO di;
   int cLines = count_lines_in_selection();
   while(cLines)
   {
      get_line(line);

      if(pos('[ \t]*dir[ \t]*=[ \t]*{\+|}{?@}', line, 1, 'ir') == 1)
      {
         _str tmp1 = strip(substr(line, pos('S0'), pos('0')));
         _str tmp2 = strip(substr(line, pos('S1'), pos('1')));

         di.fRecurse = (tmp1 == '+');
         di.fExclude = false;

         if(substr(tmp2, 1, 1) == '"')
         {
            if(pos('"{[~"]@}"', tmp2, 1, 'ir'))
            {
               tmp1 = substr(tmp2, pos('S0'), pos('0'));
               tmp2 = substr(tmp2, tmp1._length() + 1);
            }
            else
            {
               tmp1 = substr(tmp2, 2);
               tmp2 = '';
            }
         }
         else if(pos('^{[~,]@}', tmp2, 1, 'ir'))
         {
            tmp1 = substr(tmp2, pos('S0'), pos('0'));
            tmp2 = substr(tmp2, tmp1._length() + 1);
         }
         else
         {
            tmp1 = tmp2;
            tmp2 = '';
         }
         di.dir = expand_env_vars(strip(tmp1));
         while(last_char(di.dir) == FILESEP)
            di.dir = substr(di.dir, 1, di.dir._length() - 1);

         di.filespec = '';
         if(!di.fExclude)
         {
            if(pos(',[ \t]*{?@}$', tmp2, 1, 'ir'))
            {
               di.filespec = strip(substr(tmp2, pos('S0'), pos('0')));
               if(pos('"', di.filespec) == 1)
               {
                  di.filespec = substr(di.filespec, 2);
                  int posEndQuote = pos('"', di.filespec);
                  if(posEndQuote)
                     di.filespec = substr(di.filespec, 1, posEndQuote - 1);
               }
            }
         }
         translate_wildcard_list(di.filespec, aliases);

         if(di.dir != '')
         {
            if(s_isDebugging >= 3)
               say('dir'(di.fRecurse ? ' recurse' : '')' "'di.dir'", filespec "'di.filespec'"');

            dir_list[dir_list._length()] = di;
         }
      }
      else if(pos('[ \t]*exclude[ \t]*={?@}', line, 1, 'ir') == 1)
      {
         di.fRecurse = false;
         di.fExclude = true;
         di.dir = strip(substr(line, pos('S0'), pos('0')));
         di.filespec = '';

         if(s_isDebugging >= 3)
            say('exclude "'di.dir'"');

         dir_list[dir_list._length()] = di;
      }

      down();
      cLines--;
   }
}

/**
 * Finds and selects section for specified project.  Assumes the current
 * buffer is the ini file temp view.
 */
static bool dinfo_find_project(_str projName, _str wksName)
{
   while(true)
   {
      // Find project.
      _begin_line();
      if(0 != search('^[ \t]*\[[ \t]*'_escape_re_chars(strip(projName),'r')'[ \t]*\][ \t]*(;?*|)$', 'ir'))
         break;
      int sectionLine = p_line;

      // Select the matching section.
      _deselect();
      if(0 != down())
         break; // Special case:  an empty project on the last line of the file is considered to not actually exist.
      _select_line();
      if(0 == search('^[ \t]*\[', 'ir'))
         up();
      else
         bottom();
      _select_line();
      if(p_line <= sectionLine)
      {
         _deselect();
         break;
      }

      // Check that the workspace matches, if specified.
      if(0 == search('^[ \t]*workspace[ \t]*=[ \t]*{?@}$', 'irm'))
      {
         if(!strieq(strip(get_match_text(0)), strip(wksName)))
         {
            _end_select();
            if(0 != down())
               break;
            continue;
         }
      }

      return true;
   }

   return false;
}

/**
 * Copies the dir list elements for <i>projName</i> to the <i>dir_list</i>
 * array.
 *
 * @param dir_list   Array to which to append.
 * @param projName   Name of project.
 * @param wksName    Name of workspace.
 * @param aliases    Array of alias definitions.
 *
 * @return bool   Returns true if <i>projName</i> is recognized, otherwise
 *                   returns false.
 *
 * @see DIRINFO
 */
static bool dinfo_get_project(DIRINFO (&dir_list)[], _str projName, _str wksName, _str project, _str (&aliases):[])
{
   bool reloadIni = true;
   bool loadingGlobalIni = false;

   // Load the project definitions from the ssync.ini file.
   // Find ini file.

   // First, we look for a file in the project directory with
   // filename <project_name>.ini
   _str iniFile = _strip_filename(project, 'E')'.ini';
   _str prjIniFile = iniFile;
   if (path_exists(iniFile))
   {
      // Project ini file exists, it must be reloaded
      reloadIni = true;
      loadingGlobalIni = false;
   }
   else
   {
      // If <project_name>.ini does not exist, then use 'ssync.ini'
      // in the slickedit configuration directory.
      iniFile = slick_path_search1("ssync.ini");
      loadingGlobalIni = true;
      if((s_idIni >= 0) && (!s_fReloadIni) && (s_fGlobalIniLoaded))
      {
         reloadIni = false;
      }
   }

   if(iniFile == '')
   {
      _message_box("Unable to find ssync.ini or "prjIniFile" file.");
      return false;
   }

   if ( reloadIni )
   {
      // Delete our temp view of the ini file, if we have one.
      ini_discard();

      // Create temp view and load ini file.
      int idTmp;
      int idOrig = _create_temp_view(idTmp);
      if(idOrig == '')
      {
         _message_box("Error creating temp view of ini file.");
         return false;
      }
      s_idIni = idTmp;
      get(iniFile);
      ini_get_aliases(aliases);
      activate_window(idOrig);
      if ( loadingGlobalIni )
      {
         s_fGlobalIniLoaded = true;
      }
      else
      {
         s_fGlobalIniLoaded = false;
      }
      s_fReloadIni = false;
   }

   // Find the project in the ini file, then add its entries.
   bool fProjectFound = false;
   int idOrig;
   _str ss;
   save_selection(ss);
   get_window_id(idOrig);
   activate_window(s_idIni);
   top();
   if(dinfo_find_project(projName, wksName))
   {
      DIRINFO diProject[];
      DIRINFO diAlways[];

      fProjectFound = true;

      // Add the dir list entries.
      dinfo_add(diProject, aliases);

      // Insert entries from ALWAYS pseudo-project if it exists.
      top();
      if(dinfo_find_project("ALWAYS", wksName))
         dinfo_add(diAlways, aliases);

      int ii;
      for(ii = 0; ii < diAlways._length(); ii++)
         dir_list[dir_list._length()] = diAlways[ii];
      for(ii = 0; ii < diProject._length(); ii++)
         dir_list[dir_list._length()] = diProject[ii];
   }

   activate_window(idOrig);
   restore_selection(ss);
   return fProjectFound;
}

/**
 * Expand env vars in <i>s</i>.  Env vars must be in the format "%envvar%"
 * (closing % is needed).
 *
 * <p><b>Implementation Notes:</b><br>
 * The current implementation will go into an infinite loop if there is a
 * cycle in the expanded env vars.  Since I've never encountered such a
 * situation in the real world, and I don't know offhand how CMD or etc
 * resolve such situation, I'm sticking my head in the sand and pretending
 * such things don't happen.  Please try not to prove me wrong.
 *
 * @param s          String in which to expand env vars.
 *
 * @return _str      String with the expanded env vars.
 */
static _str expand_env_vars( _str s )
{
   _str new_s = '';

   while ( pos( '(%([A-Za-z_0-9]+)%)', s, 1, 'U' ) )
   {
      int cchBefore = pos( 'S1' ) - 1;
      int cchAfter = length( s ) - ( pos( 'S1' ) + pos( '1' ) - 1 );
      new_s = '';
      if ( cchBefore )
         new_s = new_s :+ substr( s, 1, cchBefore );
      new_s = new_s :+ get_env( substr( s, pos( 'S2' ), pos( '2' ) ) );
      if ( cchAfter )
         new_s = new_s :+ substr( s, length( s ) - ( cchAfter - 1 ), cchAfter );
      s = new_s;
   }

   return s;
}

/**
 * Builds a hash array of the files in the project.
 */
static void ssync_getprojectfilelist(_str ProjectName, int (&projectfiles_list):[])
{
   _str filelist = "";
   int file_view_id = 0;
   int orig_view_id = p_window_id;

   GetProjectFiles(ProjectName, file_view_id);
   p_window_id = file_view_id;

   top();
   up();

   while(!down())
   {
      _str filename;

      get_line(filename);
      filename = strip(filename, 'B');

      if(filename != "")
      {
         if(_fpos_case != '')
            filename = lowcase(filename);
         projectfiles_list:[filename] = 0;
      }
   }

   p_window_id = orig_view_id;
   _delete_temp_view(file_view_id);
}

