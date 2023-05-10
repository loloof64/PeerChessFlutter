# Peer Chess

Play chess remotely with your friends.

## Developers

### Setting up secrets

1. create a folder **secrets** in the **assets** folder.
2. add credentials for Open Relay Free Turn Server in a file called **turn_credentials.json** under the **secrets** folder : you must provide a **string** value for `apiKey` key.
3. add secrets for signalling server in a file called **firebase.json** under the **credentials** folder : you must provide your firebase project conifguration (**string** values for key `projectId`).

### Building for Windows

#### Configuration

1. Install Visual Studio with the C++ framework for Desktop application
2. Install Flutter

#### Building

1. Add file app_icon.ico in the folder #PROJECT_ROOT#/windows/runner/resources
2. Compile in Release mode
3. Add all these elements in a common folder :
   1. The folder #PROJECT_ROOT#//build/windows/runner/Release
   2. The following DLL files, from the folder C:/Windows/System32, into the folder Release, that you copied just before:
      * msvcp140.dll
      * vcruntime140.dll
      * vcruntime140_1.dll
   3. You can now zip the content of the Release folder, as it will be the content of the application.

## Credits

* Free Serif font has been downloaded from [Fonts2u](https://fr.fonts2u.com/)
* Using and adapted code from [Duration Picker Dialog](https://github.com/ashutosh2014/duration_picker_dialog_box/)
