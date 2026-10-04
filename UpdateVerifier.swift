import Foundation
import Security

/// Asks macOS whether a downloaded copy is the same app, from the same signer, as the one running.
/// This is the test macOS itself applies before honouring Accessibility and Input Monitoring,
/// so a copy that passes keeps those approvals.
enum UpdateVerifier {
    static func requirementOfRunningApp() throws -> SecRequirement {
        var running: SecCode?
        try expect(SecCodeCopySelf([], &running), "read this app's signature")
        var code: SecStaticCode?
        try expect(SecCodeCopyStaticCode(running!, [], &code), "read this app's signature")
        return try requirement(of: code!)
    }

    static func requirement(ofAppAt url: URL) throws -> SecRequirement {
        try requirement(of: staticCode(url))
    }

    /// True for a copy signed without a certificate: macOS knows it only by its exact bytes,
    /// so no other build can ever match it.
    static func isAdHoc(appAt url: URL) -> Bool {
        guard let code = try? staticCode(url) else { return true }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any] else { return true }
        if let flags = details[kSecCodeInfoFlags as String] as? UInt32,
           flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return true }
        return (details[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []).isEmpty
    }

    static func check(_ candidate: URL, satisfies requirement: SecRequirement) throws {
        let code: SecStaticCode
        do { code = try staticCode(candidate) } catch { throw UpdateFailure.signatureMismatch("it has no readable signature") }
        var errors: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &errors)
        let detail = errors?.takeRetainedValue()
        guard status == errSecSuccess else {
            throw UpdateFailure.signatureMismatch(reason(status, detail))
        }
    }

    static func version(ofAppAt url: URL) -> AppVersion? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = info["CFBundleShortVersionString"] as? String else { return nil }
        return AppVersion(text)
    }

    static func text(of requirement: SecRequirement) -> String {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return "" }
        return text as String
    }

    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        try expect(SecStaticCodeCreateWithPath(url as CFURL, [], &code), "read the signature of \(url.lastPathComponent)")
        return code!
    }

    private static func requirement(of code: SecStaticCode) throws -> SecRequirement {
        var requirement: SecRequirement?
        try expect(SecCodeCopyDesignatedRequirement(code, [], &requirement), "read the signer")
        return requirement!
    }

    private static func expect(_ status: OSStatus, _ action: String) throws {
        guard status == errSecSuccess else {
            throw UpdateFailure.signatureMismatch("macOS could not \(action) (\(reason(status, nil)))")
        }
    }

    private static func reason(_ status: OSStatus, _ error: CFError?) -> String {
        if status == errSecCSReqFailed { return "it is not signed by the same developer as this copy" }
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "code \(status)"
        if let error, let detail = CFErrorCopyDescription(error) as String?, !detail.isEmpty, detail != text {
            return "\(text): \(detail)"
        }
        return text
    }
}
