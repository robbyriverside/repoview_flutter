# Repo View Tool

Repoview is a desktop software tool that provides visuals for any folder (or repo).
The contents of the folder show in the view as soon as the file or folder is added.

The content in the folder is synchronized with the view.
If the folder adds or removes files, or subfolders, then that changes the view.
If a file or folder is dragged onto the RepoView window, that file is added to the view AND the folder.

RepoView provides a visual for every type of file. Graphic files show the image in the view.
A folder shows a tree viewer and the names of the files within it.

The design goal is to  have a visual for every file type.  But it can also contain various shapes
(rectangle, circle, etc.) that have no relationship to a file.  These allow creation of graphs.

One way to save the folder/project is to use GitHub to store the project.
There are many features that can access the Repository directly.  But a local folder tree is
preferred.

## How it works

The repo is given a visual by adding a ".repoview.rvg" system file to the folder, or the tool will add
one for you.  This system file is how the tool knows there is a visual representation.  When the
tool identifies a system RVG file, it sychronizes it with the files in the folder.  So files
that were added since the last tool use will be added to the view or removes the file visual if a file
is missing.  

Note: we use the file extension ".rvg" to keep track of valid RepoView files. RVG stands for Repo
View Graph.  Borrowed from the ".svg" for scalable vector graphics.  But an ".rvg" file is expected
to contain JSON.  It should never be hand edited.  But nothing prevents that from happening.
So the file can be manually fixed, if necessary.

But it the repoview RVG file can be used to create a custom view.  The custom view could be for
a simple diagram objects.  The tool can identify these files and render their view
inside the view for that non-system RepoView diagram.  For example, architecture.rvg might contain
a block diagram of the system architecture and not reference any files in the repo.

Say you had a new folder that has never had a visual.  If you tell RepoView to open that folder
it would generate a complete system RVG file (".repoview.rvg").  The user can adjust the visual
by moving the items around in the viewer.  

## RVG Diagrams

The items in the view can be connected via lines with arrows.  A double arrow is just two single
arrows in both directions.  Files, like images, can be dragged onto the view and the image will be
added to the folder.  That is true of any kind of file, but when they are dragged on the view an
item is added into the folder.  If you hold down the shift key and drop a file, then it doesn't
copy the file into the view, it simply references it's original location.  

The RVG file is a list of JSON objects for the items stored in the view.  The item object contains
size, location, color and connections as a system basis.  The system displays a reasonable size for
the image if it is too big or too small.  The user can change the item size.  But every effort is
made to fit the image into the view.  

RepoView makes every effort, including using AI, to make a nice looking view.  There are RepoView
formatters that can create mind maps or many other ways to cleanup the view.  This will be the
source of many RepoView enhancements.

## Philosophy

 even though this entire display is based on objects, many of whom relate to files, the fact that
 their files is not the important part.  If we just wanna look at files, there are plenty of
 interfaces. That'll do that. This allows us to make a picture of what's in the directory.
  In that context, the fact that the object correlates to a file is just a implementation detail,
  not the primary purpose.
  
The name of the file should not be shown on the item window.  There's a way to toggle the names
back on for the entire diagram.  But by default it is off.  The viewer is for displaying the contents of the file, rather
than it's name.  But the name may be useful as a toggle on the view.  So the filename overlays the
item window and hence obscures the file contents if any.