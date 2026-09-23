//
//  UnixSharedFolderManager.swift
//  SheepShaver_Xcode8
//
//  Owns the configurable shared "UNIX" (extfs) folder path.
//  macOS: absolute POSIX path chosen via NSOpenPanel.
//  iOS/iPadOS: security-scoped folder URL chosen via UIDocumentPicker(.folder),
//  persisted as bookmark data, with copy-into-container fallback.
//

import Foundation
import UIKit

enum UnixSharedFolderError: Error {
	case notADirectory
	case notReadable
	case bookmarkCreationFailed
	case bookmarkUnresolvable
}

private struct UnixSharedFolderConfig: Codable {
	var macPath: String?
	var bookmarkBase64: String?
}

@MainActor
class UnixSharedFolderManager {

	static let shared = UnixSharedFolderManager()

	private static let pathDefaultsKey = "UnixSharedFolder.path.v1"
	private static let bookmarkDefaultsKey = "UnixSharedFolder.bookmark.v1"

	private var config: UnixSharedFolderConfig

	/// Security-scoped access held for the duration of emulation on iOS.
	private var activeSecurityScopedURL: URL?

	init() {
		var loaded = UnixSharedFolderConfig(macPath: nil, bookmarkBase64: nil)
		if let data = Storage.shared.load(from: .unixSharedFolder),
		   let decoded = try? JSONDecoder().decode(UnixSharedFolderConfig.self, from: data) {
			loaded = decoded
		} else {
			// Migrate from legacy UserDefaults keys if present.
			let defaults = UserDefaults.standard
			let legacyPath = defaults.string(forKey: Self.pathDefaultsKey)
			let legacyBookmark = defaults.string(forKey: Self.bookmarkDefaultsKey)
			if legacyPath != nil || legacyBookmark != nil {
				loaded = UnixSharedFolderConfig(macPath: legacyPath, bookmarkBase64: legacyBookmark)
			}
		}
		self.config = loaded
	}

	// MARK: - Effective path passed to the emulator core (extfs pref)

	/// Resolved URL, falling back to the app Documents folder (current behavior).
	var effectiveURL: URL {
		if let custom = resolvedCustomURL() {
			return custom
		}
		return FileManager.documentUrl
	}

	/// Absolute POSIX path written via `objc_replaceString("extfs", ...)`.
	var effectivePath: String {
		effectiveURL.path
	}

	var isUsingDefault: Bool {
		resolvedCustomURL() == nil
	}

	/// Short display string for the preferences cell subtitle.
	var displayPath: String {
		let path = effectivePath
		let abbreviated = (path as NSString).abbreviatingWithTildeInPath
		return isUsingDefault ? "\(abbreviated) (Default)" : abbreviated
	}

	// MARK: - macOS: absolute path

	func setMacPath(_ path: String) throws {
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
		      isDir.boolValue else {
			throw UnixSharedFolderError.notADirectory
		}
		guard FileManager.default.isReadableFile(atPath: path) else {
			throw UnixSharedFolderError.notReadable
		}
		#if targetEnvironment(macCatalyst)
		config.macPath = path
		#else
		if UIDevice.deviceType == .mac {
			config.macPath = path
		} else {
			config.macPath = path
		}
		#endif
		save()
		PreferencesManager.shared.writePreferences()
	}

	// MARK: - iOS: security-scoped bookmark

	/// Persist a folder URL picked via UIDocumentPicker(.folder).
	/// Caller must have already started security-scoped access.
	func setIOSFolder(url: URL, bookmark: Data) throws {
		var isDir: ObjCBool = false
		// Prefer checking through the security-scoped URL while access is held.
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
		      isDir.boolValue else {
			throw UnixSharedFolderError.notADirectory
		}
		config.bookmarkBase64 = bookmark.base64EncodedString()
		config.macPath = nil
		save()
		PreferencesManager.shared.writePreferences()
	}

	/// Bookmark options, platform-conditional: `.withSecurityScope` exists
	/// only in the macOS SDK, so the iOS build must not reference it at
	/// all — pure `#if`, no runtime branching. On iOS a `.minimalBookmark`
	/// round-trips the document-picker folder URL; the URL is security-scoped
	/// regardless (including Designed-for-iPad on Mac), and access is via
	/// `startAccessingSecurityScopedResource()` at launch.
	func makeBookmark(for url: URL) throws -> Data {
		do {
			#if targetEnvironment(macCatalyst)
			return try url.bookmarkData(
				options: .withSecurityScope,
				includingResourceValuesForKeys: nil,
				relativeTo: nil
			)
			#else
			// iOS (incl. Designed-for-iPad on Mac): security-scoped via the
			// picker URL itself; .minimalBookmark persists it.
			return try url.bookmarkData(
				options: .minimalBookmark,
				includingResourceValuesForKeys: nil,
				relativeTo: nil
			)
			#endif
		} catch {
			throw UnixSharedFolderError.bookmarkCreationFailed
		}
	}

	/// Resolve the persisted bookmark. Returns nil when unset or unresolvable.
	/// If stale, the bookmark is transparently renewed and re-saved.
	func resolveBookmark() -> URL? {
		guard let base64 = config.bookmarkBase64,
		      let data = Data(base64Encoded: base64) else {
			return nil
		}
		do {
			var isStale = false
			#if targetEnvironment(macCatalyst)
			let url = try URL(
				resolvingBookmarkData: data,
				options: [.withSecurityScope],
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			)
			#else
			// iOS (incl. Designed-for-iPad on Mac): resolve with [].
			let url = try URL(
				resolvingBookmarkData: data,
				options: [],
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			)
			#endif
			if isStale {
				// Renew only while we hold access; best-effort otherwise.
				let didStart = url.startAccessingSecurityScopedResource()
				defer { if didStart { url.stopAccessingSecurityScopedResource() } }
				if let renewed = try? makeBookmark(for: url) {
					config.bookmarkBase64 = renewed.base64EncodedString()
					save()
				}
			}
			return url
		} catch {
			return nil
		}
	}

	// MARK: - Launch handoff

	/// Called by PreferencesManager before writing `extfs`.
	/// Starts security-scoped access on iOS and returns the absolute path.
	/// Falls back to Documents when unset/unresolvable.
	func prepareForEmulatorLaunch() -> String {
		stopActiveSecurityScope()
		#if targetEnvironment(macCatalyst)
		if let path = config.macPath,
		   directoryIsReadable(path) {
			return path
		}
		return FileManager.documentUrl.path
		#else
		if UIDevice.deviceType == .mac {
			if let path = config.macPath,
			   directoryIsReadable(path) {
				return path
			}
			return FileManager.documentUrl.path
		}
		// iOS/iPadOS: resolve bookmark and hold access for the session.
		if let url = resolveBookmark() {
			if url.startAccessingSecurityScopedResource() {
				activeSecurityScopedURL = url
			}
			if directoryIsReadable(url.path) {
				return url.path
			}
			stopActiveSecurityScope()
		}
		return FileManager.documentUrl.path
		#endif
	}

	func endEmulatorSession() {
		stopActiveSecurityScope()
	}

	// MARK: - Copy-into-container fallback (iOS)

	/// Copies the contents of a picked folder into Documents/<folderName> and
	/// returns that in-container URL, for use when a bookmark cannot persist.
	func copyFolderIntoContainer(sourceURL: URL) throws -> URL {
		let didStart = sourceURL.startAccessingSecurityScopedResource()
		defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
		let destURL = FileManager.documentUrl
			.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
		let coordinator = NSFileCoordinator()
		var coordError: NSError?
		var copyError: Error?
		coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordError) { readURL in
			do {
				if FileManager.default.fileExists(atPath: destURL.path) {
					try FileManager.default.removeItem(at: destURL)
				}
				try FileManager.default.copyItem(at: readURL, to: destURL)
			} catch {
				copyError = error
			}
		}
		if let copyError { throw copyError }
		if let coordError { throw coordError }
		return destURL
	}

	// MARK: - Reset

	func resetToDefault() {
		config = UnixSharedFolderConfig(macPath: nil, bookmarkBase64: nil)
		stopActiveSecurityScope()
		save()
		PreferencesManager.shared.writePreferences()
	}

	// MARK: - Private

	private func resolvedCustomURL() -> URL? {
		#if targetEnvironment(macCatalyst)
		if let path = config.macPath,
		   directoryIsReadable(path) {
			return URL(fileURLWithPath: path, isDirectory: true)
		}
		return nil
		#else
		if UIDevice.deviceType == .mac {
			if let path = config.macPath,
			   directoryIsReadable(path) {
				return URL(fileURLWithPath: path, isDirectory: true)
			}
			return nil
		}
		if let url = resolveBookmark(),
		   directoryIsReadable(url.path) {
			return url
		}
		return nil
		#endif
	}

	private func directoryIsReadable(_ path: String) -> Bool {
		var isDir: ObjCBool = false
		return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
			&& isDir.boolValue
			&& FileManager.default.isReadableFile(atPath: path)
	}

	private func stopActiveSecurityScope() {
		if let url = activeSecurityScopedURL {
			url.stopAccessingSecurityScopedResource()
			activeSecurityScopedURL = nil
		}
	}

	private func save() {
		do {
			let data = try JSONEncoder().encode(config)
			Storage.shared.save(data, at: .unixSharedFolder)
		} catch {}
	}
}
