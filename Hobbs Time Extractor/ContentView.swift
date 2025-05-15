//
//  ContentView.swift
//  Time Extractor
//
//  Created by Jonathan Anderson on 5/13/25.
//

import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct ContentView: View {
    @State private var showImporter = false
    @State private var flightTimes: [FlightTime] = []
    @State private var errorMessage: String?
    
    var body: some View {
        VStack {
            // Multi‑file importer
            Button("Import CSV(s)") {
                showImporter.toggle()
            }
            .padding()
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType.commaSeparatedText],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    errorMessage = nil
                    // Parse each file (unparsable ones yield nil epochs)
                    flightTimes = urls.map { GarminExtractor.extract(from: $0) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }

            if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .padding()
            }

            // Results table
            List {
                HStack {
                    Text("File Name").bold().frame(width: 120, alignment: .leading)
                    Spacer()
                    Text("Start (UTC)").bold()
                    Spacer()
                    Text("End (UTC)").bold()
                    Spacer()
                    Text("Time (H.h)").bold()
                }
                ForEach(flightTimes, id: \.fileName) { ft in
                    HStack {
                        Text(ft.fileName)
                            .frame(width: 120, alignment: .leading)
                        Spacer()
                        Text(ft.start)
                        Spacer()
                        Text(ft.end)
                        Spacer()
                        Text(ft.dt)
                    }
                }
            }
            .padding()
        }
    }

}

#Preview {
    ContentView()
}
