//
//  Item.swift
//  HealthDashboard
//
//  Created by Mark Calabrese on 1/21/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
