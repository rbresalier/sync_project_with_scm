# SlickEdit Automated Project File Adding

This macro will automatically update the current project's file list by
scanning directories and files that are specified in a developer
controlled.ini file.  This frees a developer from manually adding/removing
files that they added themselves or that other developers (who may not use
SE) added. Simply run this macro to have this done automatically.

The specific directories and files to scan are based on dir list
definitions in either a "&lt;project_name&gt;.ini" file in the same
directory as your project ("&lt;project_name&gt;.vpj") file or an
"ssync.ini" file in your SlickEdit config directory.  Edit the
"&lt;project_name&gt;.ini" or ssync.ini file to describe your projects.
If both files exist, then "&lt;project_name&gt;.ini" will be used.

Long term, SlickEdit needs improved native support for efficiently
automatically updating the list of files in a project.

This macro comes from the following discussion on the SlickEdit forum:
https://community.slickedit.com/index.php/topic,3262.30.html

# Usage
* Use "ssync" to sync the current project.
* Use "ssync -a" to sync all projects in the current workspace.

# History
* 2017-12-17: Modified by Rob Bresalier to make the file scanning much faster by
  having 1 call to insert_file_list per base directory for all filespecs and all exclusions.
* 2017-12-03: Modified by Rob Bresalier to use the "&lt;project_name&gt;.ini" file
* 2008-2013: Original macro written by mikesart and chrisant

# Format of the SSYNC.INI file:
```
[ProjectName]
workspace=WorkspaceName                (OPTIONAL LINE)
dir=baseDirectory1, wildcards
dir=baseDirectory2, wildcards
dir=baseDirectory3, wildcards
...etc
exclude=antpattern1
exclude=antpattern2
...etc
```

## workspace line
The "workspace=" line is optional, and can be used to disambiguate between
two projects with the same name that are in different workspaces.

## dir line
A "dir=" line specifies a base directory to scan.  Prefix the base
directory with a plus sign ("+") to scan recursively.

A directory can be relative (in which case it is relative to the project
directory) or it can be absolute.  It can refer to environment variables.
It must be surrounded in double quote marks if it contains commas (when in
doubt, surround the directory name in double quote marks).

The "wildcards" on a "dir=" line are optional and can be used to filter the
matching files (by default all files match). Separate multiple wildcards
with semicolons (for example "\*.c;\*.cpp;\*.h"). The wildcards follow
"ant pattern" syntax which is documented here:
https://ant.apache.org/manual/dirtasks.html

Also certain special keywords in angled brackets are recognized as
synonyms for groups of wildcards. See translate_wildcard_list() in
sync_project_with_scm.e for the list of supported keywords (or to
add/modify the keywords).

## exclude line
An "exclude=" line can specify an ant pattern to exclude within each
directory scan. Examples:

Example 1: Exclude all directories named .git, such as basedir/.git, basedir/subdir1/.git, etc:
```
exclude=**/.git/
```

When specifying a directory to exclude such as the .git above, make sure
it ends with a trailing slash in order to exclude all files beneath that
directory.  If only specified \*\*/.git without the trailing slash, then
it would only exclude files named .git but not the contents of directories
named .git.  Also make sure to specify the initial \*\*/ to indicate any
directory pattern above .git to match the exclude pattern.

Example 2: Exclude all object files with .o extension:
```
exclude=**/*.o
```

For any extension (such as .o files) that you want to exclude, make sure
to use the \*\*/\*.ext syntax.  If you only used \*.ext, then only the
\*.ext files in the base directory would get excluded, but \*.ext files in
subdirectories would still be included.  By using \*\*/, you are telling
it to also match any directory pattern above the .ext.

## [ALWAYS] project

There can also be a specialpseudo-project "[ALWAYS]" which is effectively
prepended at runtime to the beginning of each other project in the .ini
file.  This exists because mikesart wanted his SE macros and build files
to be in all of his projects.

# Optimizing for faster scans

Each dir= line will invoke 1 call to "insert_file_list()" to scan the
specified directories/files in a base directory.  To improve the speed of
the scanning, you will want to make sure that any directory is only
scanned once and not multiple times.

Here is an example that can be optimized where 2 directories with some
overlap are to be scanned:

```
[projectname]
dir=+../basedir, *.c; *.h
dir=+../basedir/specialdir, *
```

In the above example, "basedir/specialdir" will end up getting scanned 2
times due to a distinct scan for each dir line.

If you wanted to optimize this to have "basedir/specialdir" only scanned 1
time and achieve the same result as having the 2 dir= lines, you can use
only 1 dir= line by doing this instead:

```
[projectname]
dir=../basedir, **/*.c; **/*.h; specialdir/**
```

Notice in the above that we removed the "+" (for recursion) before
"../basedir".  The reason for doing this is because we only want to scan
all files under 'basedir/specialdir' and we don't want to scan for all
files in other directories named 'specialdir' that are not directly under
basedir (such as ../basedir/dir1/specialdir).

We still want to recurse all subdirectories for \*.c and \*.h files, but
since we removed the "+", we need to specify recursion for only these 2
file types.  This is done by changing the wildcard patterns to be prefixed
with \*\*, such as \*\*/\*.c and \*\*/\*.h.  Using the \*\* will cause
recursion to occur for these wildcard patterns only, even though the "+"
was removed.  This trick came out of the following discussion on the SE
forum:
https://community.slickedit.com/index.php/topic,15501.msg59475.html#msg59475

