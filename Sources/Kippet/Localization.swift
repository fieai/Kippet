import Foundation

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let translation = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? translation : String(format: translation, arguments: arguments)
}
