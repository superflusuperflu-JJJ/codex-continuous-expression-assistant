// Local development identity. Private key access is limited to Apple's codesign tool.
import Foundation
import AppKit
import Security
import Darwin

func checked(_ status: OSStatus, _ operation: String) throws {
    if status != errSecSuccess { throw NSError(domain:operation,code:Int(status),userInfo:[NSLocalizedDescriptionKey:operation+": "+(SecCopyErrorMessageString(status,nil) as String? ?? String(status))]) }
}
func searchList() throws -> [SecKeychain] {
    var raw: CFArray?
    try checked(SecKeychainCopySearchList(&raw),"read keychain search list")
    guard let list = raw as? [SecKeychain] else { throw NSError(domain:"keychain search list",code:1) }
    return list
}
func path(_ keychain: SecKeychain) throws -> String {
    var buffer = [CChar](repeating:0,count:4096), length: UInt32 = 4096
    try checked(SecKeychainGetPath(keychain,&length,&buffer),"read keychain path")
    return String(cString:buffer)
}
func unlocked(_ folder: URL) throws -> SecKeychain {
    var keychain: SecKeychain?
    try checked(SecKeychainOpen(folder.appendingPathComponent("identity.keychain-db").path,&keychain),"open private signing keychain")
    let password = try String(contentsOf:folder.appendingPathComponent("keychain-password"),encoding:.utf8)
    try password.withCString { ptr in try checked(SecKeychainUnlock(keychain,UInt32(password.utf8.count),ptr,true),"unlock private signing keychain") }
    return keychain!
}
func sign(_ folder: URL, arguments: [String]) throws {
    guard arguments.first == "codesign" else { throw NSError(domain:"unsupported signing tool",code:1) }
    let lock = Darwin.open(folder.appendingPathComponent("signing.lock").path,O_CREAT | O_RDWR,0o600)
    guard lock >= 0 else { throw NSError(domain:"open signing lock",code:Int(errno)) }
    defer { Darwin.close(lock) }
    guard flock(lock,LOCK_EX) == 0 else { throw NSError(domain:"lock signing operation",code:Int(errno)) }
    defer { flock(lock,LOCK_UN) }
    let keychain = try unlocked(folder), original = try searchList(), ownPath = try path(keychain)
    let alreadyPresent = try original.contains { try path($0) == ownPath }
    if !alreadyPresent { try checked(SecKeychainSetSearchList((original+[keychain]) as CFArray),"temporarily include signing certificate chain") }
    let result = Result { () throws -> Void in
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/codesign"); process.arguments = Array(arguments.dropFirst())
        process.standardError = errors; try process.run()
        let text = String(data:errors.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain:"signing preflight",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
    }
    if !alreadyPresent {
        // Preserve concurrent changes and remove only the entry this operation temporarily added.
        let current = try searchList(), restored = try current.filter { try path($0) != ownPath }
        try checked(SecKeychainSetSearchList(restored as CFArray),"restore keychain search list")
    }
    try result.get()
}

let gui = CommandLine.arguments.count < 3
let mode = gui ? "trust" : CommandLine.arguments[1]
let folder = gui ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextCapturePrototype/Signing") : URL(fileURLWithPath:CommandLine.arguments[2])
let keychainPath = folder.appendingPathComponent("identity.keychain-db").path
let passwordURL = folder.appendingPathComponent("keychain-password")
if gui {
    NSApplication.shared.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
    let alert = NSAlert(); alert.messageText = "设置原型的固定签名身份"
    alert.informativeText = "仅为这张本机开发证书保存限定规则：当前用户、代码签名用途、仅 /usr/bin/codesign。私钥不上传，不设置系统级或网页 HTTPS 信任。系统若请求密码，请你亲自输入。"
    alert.addButton(withTitle:"保存限定规则"); alert.addButton(withTitle:"取消")
    guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }
}
do {
    if mode == "create" {
        let original = try searchList()
        defer { _ = SecKeychainSetSearchList(original as CFArray) }
        var random = [UInt8](repeating:0,count:32)
        try checked(SecRandomCopyBytes(kSecRandomDefault,random.count,&random),"generate keychain password")
        let password = random.map { String(format:"%02x",$0) }.joined()
        guard FileManager.default.createFile(atPath:passwordURL.path,contents:Data(password.utf8),attributes:[.posixPermissions:0o600]) else { throw NSError(domain:"create password file",code:1) }
        var keychain: SecKeychain?
        try password.withCString { ptr in try checked(SecKeychainCreate(keychainPath,UInt32(password.utf8.count),ptr,false,nil,&keychain),"create private signing keychain") }
        var trusted: SecTrustedApplication?
        try checked(SecTrustedApplicationCreateFromPath("/usr/bin/codesign",&trusted),"set codesign key access")
        var access: SecAccess?
        try checked(SecAccessCreate("ContextCapture local development signing" as CFString,[trusted!] as CFArray,&access),"create private key ACL")
        let passphrase = try String(contentsOf:folder.appendingPathComponent("import-password"),encoding:.utf8) as CFString
        let attributes = [kSecAttrIsPermanent,kSecAttrIsSensitive] as CFArray
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION); parameters.passphrase = .passUnretained(passphrase)
        parameters.accessRef = access.map { .passUnretained($0) }; parameters.keyAttributes = .passUnretained(attributes)
        var format = SecExternalFormat.formatPKCS12, type = SecExternalItemType.itemTypeAggregate
        var imported: CFArray?
        let data = try Data(contentsOf:folder.appendingPathComponent("identity.p12"))
        try withExtendedLifetime((passphrase,attributes,access)) {
            try checked(SecItemImport(data as CFData,nil,&format,&type,[],&parameters,keychain,&imported),"import signing identity")
        }
    } else if mode == "trust" {
        let data = try Data(contentsOf:folder.appendingPathComponent("certificate.cer"))
        guard let certificate = SecCertificateCreateWithData(nil,data as CFData) else { throw NSError(domain:"certificate data",code:1) }
        var trusted: SecTrustedApplication?
        try checked(SecTrustedApplicationCreateFromPath("/usr/bin/codesign",&trusted),"constrain trust to codesign")
        let settings: CFArray = [[kSecTrustSettingsPolicy as String:SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning,nil)!,kSecTrustSettingsApplication as String:trusted!,kSecTrustSettingsResult as String:SecTrustSettingsResult.trustRoot.rawValue]] as CFArray
        try checked(SecTrustSettingsSetTrustSettings(certificate,.user,settings),"save current-user codesign-only trust")
        var confirmed: CFArray?
        try checked(SecTrustSettingsCopyTrustSettings(certificate,.user,&confirmed),"read saved trust rule")
        guard let rules = confirmed as? [[String:Any]], rules.count == 1, rules[0][kSecTrustSettingsApplication as String] != nil else { throw NSError(domain:"trust readback",code:1) }
    } else if mode == "publish-certificate" {
        let data = try Data(contentsOf:folder.appendingPathComponent("certificate.cer"))
        guard let certificate = SecCertificateCreateWithData(nil,data as CFData) else { throw NSError(domain:"certificate data",code:1) }
        var defaultKeychain: SecKeychain?
        try checked(SecKeychainCopyDefault(&defaultKeychain),"read user default keychain")
        let result = SecCertificateAddToKeychain(certificate,defaultKeychain)
        if result != errSecDuplicateItem { try checked(result,"publish public certificate only") }
    } else if mode == "sign" {
        try sign(folder,arguments:Array(CommandLine.arguments.dropFirst(3)))
    } else if mode == "unlock" {
        _ = try unlocked(folder)
    } else { throw NSError(domain:"unsupported signing operation",code:1) }
    if gui {
        try JSONSerialization.data(withJSONObject:["saved":true,"scope":"current-user-codeSign-codesign-app"]).write(to:folder.appendingPathComponent("trust-result.json"),options:.atomic)
        let alert = NSAlert(); alert.messageText = "限定签名规则已保存"; alert.runModal()
    }
} catch {
    if gui {
        try? JSONSerialization.data(withJSONObject:["saved":false,"error":error.localizedDescription]).write(to:folder.appendingPathComponent("trust-result.json"),options:.atomic)
        let alert = NSAlert(); alert.messageText = "系统尚未保存限定规则"; alert.informativeText = error.localizedDescription; alert.runModal()
    }
    fputs(error.localizedDescription+"\n",stderr); exit(1)
}
