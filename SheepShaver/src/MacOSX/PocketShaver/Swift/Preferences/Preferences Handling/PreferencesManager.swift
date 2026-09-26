//
//  PreferencesManager.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-30.
//

import Foundation
import UIKit

@MainActor
class PreferencesManager {

	public static let shared = PreferencesManager()

	func writePreferences() {
		writeDiskPrefs()

		objc_addString("seriala", "/dev/null")
		objc_addString("serialb", "/dev/null")
		objc_addString("ether", "slirp")

		// Record the boot resolution from MonitorResolutionManager — the same source that
		// fills the guest's VModes[] list — so the recorded "screen" default always matches
		// a detected pixel-aligned mode (orientation/display-correct, recomputed each launch)
		// rather than the live UIScreen point size, which diverges from the detected list
		// whenever the launch orientation differs from the current device orientation.
		let bootResolution = MonitorResolutionManager.shared.bootScreenResolution
		let screenString = "dga/\(bootResolution.width)/\(bootResolution.height)"
		objc_replaceString("screen", screenString)

		objc_replaceString("sdlrender", "metal")
		// Shared UNIX folder (extfs): custom path when set, else Documents.
		// The manager resolves the iOS security-scoped bookmark and holds
		// access for the emulation session.
		objc_replaceString("extfs", UnixSharedFolderManager.shared.prepareForEmulatorLaunch())

		// PowerPC-to-native JIT (Mac Catalyst only; the core ignores the pref
		// on hosts built without the compiler)
		objc_replaceBool("jit", MiscellaneousSettings.current.jitCompilerEnabled)

		objc_savePrefs()
	}

	private func writeDiskPrefs() {
		let diskArray = DiskManager.shared.diskArray

		// Clear the prefs and rewrite them. If there is but one real disk and no remaining prefs disks, we should just
		// set the one as the prefs disk without bothering the user.
		while objc_findString("disk") != nil {
			objc_removeItem("disk")
		}
		while objc_findString("cdrom") != nil {
			objc_removeItem("cdrom")
		}

		for disk in diskArray {
			guard disk.isEnabled else {
				continue
			}

			let filePath = (DiskManager.diskStoreURL.path as NSString).appendingPathComponent(disk.filename)
			guard FileManager.default.fileExists(atPath: filePath) else {
				// The file vanished after being enabled (deleted in Finder,
				// volume unmounted, disk store switched). Writing a dead path
				// makes the guest sit in SCSI/CD probe timeouts, so skip it.
				// loadDiskData prunes the entry from the saved config on the
				// next rescan; this guard covers the window in between.
				print("- Skipped missing \(disk.type == .cd ? "cdrom" : "disk") '\(filePath)' (file not on disk)")
				continue
			}
			let name = disk.type == .cd ? "cdrom" : "disk"
			objc_addString(name, filePath)
		}

		// Ensure that /dev/poll/cdrom is present exactly once.
		var hasPollCdRom = false
		var index = 0
		while let diskString = objc_findStringWithIndex("cdrom", Int32(index)) {
			if diskString == "/dev/poll/cdrom" {
				hasPollCdRom = true
				break
			}

			index += 1
		}
		if !hasPollCdRom {
			objc_addString("cdrom", "/dev/poll/cdrom")
		}
	}
}
