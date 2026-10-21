import Foundation
import CryptoKit

struct BrowserInstallation {
    let extensionID: String
    let manifestURL: URL
    static func quoted(_ value: String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'" }
    static func install(resourceRoot: URL, pythonURL: URL, support: URL, manifestDirectory: URL) throws -> Self {
        let manager = FileManager.default
        let source = resourceRoot.appendingPathComponent("BrowserExtension")
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:source.appendingPathComponent("manifest.json"))) as? [String:Any]
        guard let publicKey = object?["key"] as? String, let key = Data(base64Encoded:publicKey) else {
            throw NSError(domain:"Installation",code:3,userInfo:[NSLocalizedDescriptionKey:"浏览器组件缺少有效公开密钥，请重新下载完整安装包。"])
        }
        let alphabet = Array("abcdefghijklmnop")
        let id = SHA256.hash(data:key).prefix(16).map { String(alphabet[Int($0 >> 4)])+String(alphabet[Int($0 & 15)]) }.joined()
        for directory in [support,support.appendingPathComponent("BrowserExtension"),manifestDirectory] {
            try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        // Copy only shipped extension files, never user profiles or runtime data.
        for name in ["manifest.json","background.js","content.js","public-key.txt"] {
            try Data(contentsOf:source.appendingPathComponent(name)).write(to:support.appendingPathComponent("BrowserExtension/"+name),options:.atomic)
        }
        let host = support.appendingPathComponent("native-host")
        let wrapper = "#!/bin/sh\nexec "+quoted(pythonURL.path)+" -B -E -s "+quoted(resourceRoot.appendingPathComponent("tools/native_host.py").path)+"\n"
        try Data(wrapper.utf8).write(to:host,options:.atomic)
        try manager.setAttributes([.posixPermissions:0o700],ofItemAtPath:host.path)
        let manifest = manifestDirectory.appendingPathComponent("local.contextcapture.bridge.json")
        try JSONSerialization.data(withJSONObject:["name":"local.contextcapture.bridge","description":"Codex连续表达助手本机连接","path":host.path,"type":"stdio","allowed_origins":["chrome-extension://"+id+"/"]],options:[.prettyPrinted,.sortedKeys]).write(to:manifest,options:.atomic)
        try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
        return Self(extensionID:id,manifestURL:manifest)
    }
}
