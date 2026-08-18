import Foundation

/// Runtime Helper 入口：由 launchd 按需启动的内嵌 XPC Service。
///
/// 只启动 XPC listener，不执行任何业务逻辑；不创建 UI；不访问用户数据。
let service = RuntimeHelperService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
RunLoop.main.run()
