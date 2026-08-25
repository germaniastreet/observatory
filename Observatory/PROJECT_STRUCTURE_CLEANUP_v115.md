# v115 Project / Git Structure Cleanup

This version stabilizes the working project structure before additional feature work.

## Canonical project root

The Git repository root is the folder that contains:

- `.git/`
- `Observatory.xcodeproj`
- `Observatory/`
- `.gitignore`

Open this project file in Xcode:

```text
Observatory.xcodeproj
```

The app source files live in:

```text
Observatory/
```

## What was fixed

- Removed the flat-file confusion from the uploaded project snapshot.
- Restored the standard Xcode structure expected by Git and the Xcode project file.
- Ensured there is exactly one active Xcode project file at the repository root.
- Ensured there is no `saved versions` folder inside the live project archive.
- Added `.gitignore` so macOS metadata, archives, build products, and recursive saved-version folders are not added accidentally.
- Preserved Git history and recreated missing v113 and v114 tags in the cleaned project history.

## What should not be added to the live project

Do not place these inside the Git working tree:

- saved-version folders
- expanded old project copies
- previous ZIP archives
- Finder-created `__MACOSX` folders
- build products
- DerivedData

## Archive policy

Future archives should be ZIP files only and should live outside the active Git repository.

Recommended external archive folder:

```text
Documents/Observatory Archives/
```

or, if keeping the current name temporarily:

```text
Documents/second archives/
```

Each archive should contain one clean working project snapshot, not previous archives nested inside it.

## Rename policy

The project is still named `second` at the Xcode target level. The display name shown to users has already been updated to Observatory. Renaming the underlying Xcode project/target/source-folder names to `Observatory` should be handled as a separate controlled version because it affects project names, schemes, bundle identifiers, signing, and documentation.

Recommended future version:

```text
v116 — Project Rename to Observatory
```

Only proceed after confirming the v115 cleaned structure builds.
