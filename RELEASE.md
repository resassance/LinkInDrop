Nearbridge 0.3.0-alpha.3 for Android, Windows and Linux.

- Received-files shortcut, including Android's built-in inbox via a read-only document provider.
- A clearly outlined desktop file/folder drop zone; choose the recipient after dropping if necessary.
- Compact dashboard with devices and transfers side by side on desktop and collapsible settings.
- Full-screen mobile remote browser with filenames using most of the row and actions in one menu.
- Automatic receive categories: Фото, Видео, Музыка, Документы, Архивы, Приложения, Другое. Transferred folder trees and photo backups preserve their structure. Sorting is enabled by default and can be disabled; existing files are not moved.
- Right-click tray menu with Open and Quit.
- Optional Android direct Wi-Fi mode for Nearbridge. All Nearbridge traffic, including relay connections and update checks, uses the selected physical Wi-Fi/Ethernet network in this mode; other applications keep their system route. The mode is off by default. If Wi-Fi disappears, Android's system route is used until Wi-Fi returns.

For NekoBox, enable LAN bypass or exclude Nearbridge (dev.resassance.nearbridge) from VPN application routing. Nearbridge cannot override an Android VPN lockdown or a VPN that refuses bypass. The direct Wi-Fi mode selects a route; it cannot guarantee that the VPN permits communication. NekoBox and physical-phone interoperability require device testing.

Update both devices. Android uses the permanent release certificate from 0.3.0-alpha.1, so installing over that version or newer preserves data and pairing. Desktop must remain running for remote file access and transfer.

Packages for all three platforms include SHA-256 files. Windows: extract the whole ZIP. Linux requires GTK 3 and Ayatana AppIndicator. Internet access without a VPN requires a self-hosted relay.
