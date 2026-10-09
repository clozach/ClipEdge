import Foundation

@main
struct IdentityMain {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath).standardizedFileURL
        print(try ContentIdentity.local(root))
    }
}
