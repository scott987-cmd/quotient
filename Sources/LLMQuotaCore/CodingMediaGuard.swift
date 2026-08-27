import Foundation

/// 编码通道与视觉通道的硬隔离。
///
/// 射击游戏截图会被部分代码模型端点判成敏感图片；一旦图片进入持久会话，
/// 后续每次恢复都会带着同一附件再次失败。编码 Agent 只消费独立视觉验收写成的
/// 文字事实，图片/录屏继续由专用多模态验收执行器处理。
public enum CodingMediaGuard {
    public static let systemPrompt = """
    【编码通道媒体隔离】不要使用 Read 打开任何图片或视频，也不要把媒体文件以 \
    base64、cat 或其他方式送进模型上下文。可以检查文件是否存在、尺寸、哈希和测试 \
    产物路径，但视觉判断只采用任务中注入的独立多模态验收文字；你负责据此改代码， \
    修完后重新产出证据，视觉结论由独立验收给出。
    """

    private static let extensions = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
        "mov", "m4v", "mp4", "avi", "mkv", "webm",
    ]

    /// 同时覆盖工作区相对路径和 Claude Code 的绝对路径规则。另禁掉最常见的
    /// shell 旁路；代码 Agent 读文本应使用 Read，不需要用 cat/base64 绕过媒体门。
    public static let disallowedReadTools: [String] = extensions.flatMap { ext in
        ["Read(**/*.\(ext))", "Read(//**/*.\(ext))"]
    } + [
        "Bash(cat *)", "Bash(base64 *)", "Bash(xxd *)", "Bash(hexdump *)",
    ]

    /// 这类服务端拒绝不是代码能力失败，而是媒体附件污染了持久会话。
    public static func poisonedSession(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("input new_sensitive")
            || text.contains("image is sensitive")
            || (text.contains("sensitive") && text.contains("messages[")
                && text.contains("image"))
    }
}
