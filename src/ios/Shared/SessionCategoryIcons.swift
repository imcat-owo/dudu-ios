// sessionCategoryIconBuiltin
// Extracted from OpenMinis Views/ContentView.swift (GPL-3.0).
// Pure data lookup: session category -> (SF Symbol name, color). No views.
import SwiftUI

func sessionCategoryIconBuiltin(for category: String?) -> (systemName: String, color: Color) {
    switch category {
    case "code":         return ("terminal.fill", .orange)
    case "writing":      return ("doc.text.fill", .blue)
    case "research":     return ("globe.americas.fill", .teal)
    case "analysis":     return ("chart.pie.fill", .indigo)
    case "creative":     return ("paintbrush.pointed.fill", .pink)
    case "chat":         return ("bubble.left.fill", .green)
    case "math":         return ("number.circle.fill", .purple)
    case "translation":  return ("character.bubble", .cyan)
    case "health":       return ("heart.fill", .red)
    case "finance":      return ("banknote.fill", .mint)
    case "travel":       return ("map.fill", .orange)
    case "education":    return ("book.closed.fill", .blue)
    case "design":       return ("paintpalette.fill", .pink)
    case "productivity": return ("calendar.badge.checkmark", .yellow)
    case "support":      return ("gearshape.fill", .brown)
    case "other":        return ("square.grid.2x2.fill", .gray)
    default:             return ("bubble.left.fill", .gray)
    }
}
