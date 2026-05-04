// Extract NetmonMenuBar class to its own file for clarity
// (class definition is in main.swift — this file adds @objc refresh exposure)

import AppKit
import Foundation

extension NetmonMenuBar {
    // Exposed so AppDelegate can trigger refresh after notification action
    @objc func refreshFromDelegate() {
        refresh()
    }
}
