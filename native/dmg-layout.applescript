on run argv
  set volumeName to item 1 of argv
  set mountPoint to item 2 of argv
  set backgroundFile to POSIX file (mountPoint & "/.background/background.png") as alias

  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      set bounds of container window to {120, 120, 780, 570}

      tell icon view options of container window
        set arrangement to not arranged
        set icon size to 104
        set text size to 13
        set background picture to backgroundFile
      end tell

      set position of item "Arco.app" of container window to {170, 225}
      set position of item "Applications" of container window to {490, 225}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
