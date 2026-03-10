//
//  MeetingSummarizerApp.swift
//  MeetingSummarizer
//
//  Created by Li on 10/03/2026.
//

import SwiftUI
import CoreData

@main
struct MeetingSummarizerApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
