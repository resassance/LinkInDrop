Nearbridge 0.3.0-alpha.2 for Android, Windows and Linux.

- Stable scrollbar without lazy page-height estimates; compact queue and folder actions.
- The photo-backup switch stops scanning and pauses photo transfers immediately. Re-enabling resumes only those jobs; manual pauses and ordinary transfers stay independent.
- Android individual shared files use persistent system document grants. Adding files or folders enables sharing, with a visible status and enable action.
- Android foreground service retains CPU and Wi-Fi availability while enabled; background, battery-exemption and notification settings are grouped together.

Update both devices. On the phone, open My files and folders and select the folder with the Android system picker. For individual files shared by older versions, remove and reselect them to obtain persistent permission. Existing folder grants remain.

For screen-off transfers enable Background transfer and allow unrestricted battery operation and notifications. Some manufacturers also require an autostart permission. Maintaining availability increases battery consumption. Android force-stop still requires reopening the app. Desktop must remain running, optionally minimized to tray. Background clipboard access remains subject to Android restrictions.

Android uses the permanent signing certificate introduced in 0.3.0-alpha.1; install over that version to keep data and pairing. Devices on 0.2 or earlier may need one uninstall; save received files first.

Internet access without a VPN still requires a self-hosted Nearbridge relay. Download the platform package and its SHA-256 file. Windows: extract the complete ZIP. Linux requires GTK 3 and Ayatana AppIndicator. Desktop builds are unsigned.
