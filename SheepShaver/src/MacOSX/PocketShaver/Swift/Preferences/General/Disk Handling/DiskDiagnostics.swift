//  DiskDiagnostics.swift
//  PocketShaver
//
//  Phase 1 diagnostics for "CD never appears on desktop" reports.
//  Logging only — no behaviour changes. All output goes to stdout with a
//  `- DiskDiagnostics` prefix so it can be picked up from the console or
//  PS_STDIO_FILE capture.

import Foundation
import UIKit

@MainActor
enum DiskDiagnostics {

	/// Called from PreferencesManager.writeDiskPrefs before the prefs are
	/// rewritten. Logs every disk/cdrom path about to be handed to the
	/// emulator core, whether the file actually exists there, and which
	/// store/home directories are in play (current store vs Documents vs
	/// legacy home vs custom UNIX folder).
	static func logLaunchHandoff(diskArray: [Disk]) {
		print("- DiskDiagnostics: launch handoff begin")

		let storeURL = DiskManager.diskStoreURL
		print("- DiskDiagnostics: diskStoreURL=\(storeURL.path)")
		print("- DiskDiagnostics: FileManager.documentUrl=\(FileManager.documentUrl.path)")
		print("- DiskDiagnostics: unixSharedFolder isUsingDefault=\(UnixSharedFolderManager.shared.isUsingDefault) effective=\(UnixSharedFolderManager.shared.effectivePath)")

		#if targetEnvironment(macCatalyst)
		let pocketHome = FileManager.pocketShaverHome.path
		let legacyHome = (NSHomeDirectory() as NSString).appendingPathComponent("PocketShaver Home")
		var legacyIsDir: ObjCBool = false
		let legacyExists = FileManager.default.fileExists(atPath: legacyHome, isDirectory: &legacyIsDir)
		print("- DiskDiagnostics: pocketShaverHome=\(pocketHome)")
		print("- DiskDiagnostics: core pocketshaver_home_directory=\(objc_pocketshaver_home_directory())")
		if legacyExists {
			let legacyContents = (try? FileManager.default.contentsOfDirectory(atPath: legacyHome)) ?? []
			print("- DiskDiagnostics: legacyHome exists=\(legacyExists) isDir=\(legacyIsDir.boolValue) contents=\(legacyContents)")
		} else {
			print("- DiskDiagnostics: legacyHome exists=false")
		}
		#endif

		let storeContents = (try? FileManager.default.contentsOfDirectory(atPath: storeURL.path)) ?? []
		print("- DiskDiagnostics: diskStore contents=\(storeContents)")

		if diskArray.isEmpty {
			print("- DiskDiagnostics: diskArray is EMPTY (no known disks)")
		}
		for disk in diskArray {
			let filePath = (storeURL.path as NSString).appendingPathComponent(disk.filename)
			let exists = FileManager.default.fileExists(atPath: filePath)
			var size: Int64 = -1
			if exists,
			   let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
			   let fileSize = attrs[.size] as? NSNumber {
				size = fileSize.int64Value
			}
			let prefName = disk.type == .cd ? "cdrom" : "disk"
			print("- DiskDiagnostics: will write \(prefName) '\(filePath)' enabled=\(disk.isEnabled) exists=\(exists) size=\(size) bootable=\(disk.isBootable) naturalType=\(disk.naturalDiskType.rawValue)")
		}

		var index = 0
		while let diskString = objc_findStringWithIndex("cdrom", Int32(index)) {
			print("- DiskDiagnostics: pre-existing cdrom[\(index)]='\(diskString)'")
			index += 1
		}

		print("- DiskDiagnostics: launch handoff end")
	}

	/// Called from DiskManager.loadDiskData after a rescan. Logs which store
	/// was scanned and what it found, so a "file vanished from the list"
	/// report can be tied to a store/folder mismatch.
	static func logRescan(storeURL: URL, candidateFilenames: [String], diskArray: [Disk]) {
		print("- DiskDiagnostics: rescan store=\(storeURL.path) candidates=\(candidateFilenames)")
		for disk in diskArray {
			print("- DiskDiagnostics: rescan known file='\(disk.filename)' type=\(disk.type.rawValue) enabled=\(disk.isEnabled) bootable=\(disk.isBootable)")
		}
	}

	/// Called from PreferencesManager.writeDiskPrefs when an enabled disk is
	/// skipped because its file is missing on disk. The guest never sees the
	/// dead path, so no probe timeout; the entry is pruned from the saved
	/// config on the next loadDiskData rescan.
	static func logSkippedMissingFile(prefName: String, filePath: String) {
		print("- DiskDiagnostics: skipped missing \(prefName) '\(filePath)' (file not on disk)")
	}
}
