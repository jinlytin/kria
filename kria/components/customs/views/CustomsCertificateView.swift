import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Uses the owner's view model; closing this sheet does not end its timed download session.
@MainActor
struct CustomsCertificateView: View {
    @ObservedObject var vm: CustomsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: CertificateSheet?
    @State private var awaitingResetConfirmation = false

    private enum CertificateSheet: String, Identifiable {
        case help, resetWarning
        var id: String { rawValue }
    }
    @State private var confirmation: Confirmation?
    @State private var confirmedFingerprint = ""
    @State private var selectedURL = ""

    private enum Confirmation {
        case install, removeTrust, resetWarning, resetFinal, share

        var title: String {
            switch self {
            case .install: "安装并信任调试根证书？"
            case .removeTrust: "撤销当前用户的 SSL 信任？"
            case .resetWarning: "重置 CA 会影响所有调试设备"
            case .resetFinal: "最后确认：重置当前 CA？"
            case .share: "开启 10 分钟临时公钥分享？"
            }
        }
    }

    private var proxyActive: Bool { vm.isRunning || vm.isStarting }
    private var resetLocked: Bool {
        proxyActive || vm.certificateBusy || vm.downloadSession != nil || vm.certificateInfo?.adminTrusted == true
    }
    private var confirmationPresented: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }
    private var sameCertificate: Bool {
        (vm.certificateInfo?.sha256Fingerprint ?? "") == confirmedFingerprint
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield").font(.title2).foregroundStyle(.tint)
                Text("证书管理").font(.title2.weight(.semibold))
                Button { sheet = .help } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain)
                    .help("证书助手：原理、安装、手机配置与排障")
                    .accessibilityLabel("打开证书助手")
                Spacer()
                if vm.certificateBusy { ProgressView().controlSize(.small) }
                Button { vm.refreshCertificateStatus() } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .disabled(vm.certificateBusy)
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    notice("仅用于你有权限的受控调试。信任根 CA 后，它可为任何域名签发证书；请核对指纹、缩小解密范围，调试结束后撤销不再需要的信任。", symbol: "exclamationmark.shield", color: .orange)
                    if let error = vm.certificateError, !error.isEmpty {
                        GroupBox("证书状态 / 操作错误") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                                Text("错误不等于“未生成”或“未信任”。下方可能是上次读取的信息，请刷新后再核对。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("重新读取状态", action: vm.refreshCertificateStatus)
                                    .disabled(vm.certificateBusy)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    if let info = vm.certificateInfo {
                        certificateDetails(info)
                        trustControls(info)
                    } else {
                        GroupBox("CA 状态") {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(vm.certificateError == nil ? "尚未生成 CA" : "暂时无法读取 CA", systemImage: "shield.lefthalf.filled")
                                    .font(.headline)
                                Text("生成后可查看身份、有效期与完整 SHA-256 指纹。生成不等于安装，也不会默认信任或开启代理。")
                                    .foregroundStyle(.secondary)
                                Button(vm.certificateBusy ? "正在处理…" : "生成 CA", action: vm.prepareCertificate)
                                    .disabled(vm.certificateBusy || proxyActive || vm.certificateError != nil)
                                if proxyActive { Text("请先停止代理再生成 CA。").font(.caption).foregroundStyle(.orange) }
                                if vm.certificateError != nil {
                                    Button("重置损坏 / 不完整 CA…", role: .destructive) { request(.resetWarning) }
                                        .disabled(resetLocked)
                                    Text("无法识别旧 DER 时，不会自动删除旧证书或旧信任。请在钥匙串中按现存证书指纹手动清理；管理员域设置也须先手动移除。")
                                        .font(.caption).foregroundStyle(.orange)
                                    Button("打开钥匙串手动管理…", action: vm.openCertificateInKeychain)
                                        .disabled(vm.certificateBusy)
                                    if proxyActive || vm.downloadSession != nil {
                                        Text("恢复前请先停止代理与临时下载。").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    phoneSharing
                    if let message = vm.message, !message.isEmpty {
                        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(22)
            }
            Divider()
            HStack {
                Text("关闭此页不停止临时分享；请手动停止，或等待 10 分钟自动到期。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .frame(width: 780, height: 760)
        .sheet(item: $sheet, onDismiss: {
            guard awaitingResetConfirmation else { return }
            awaitingResetConfirmation = false
            guard !resetLocked, sameCertificate else { return }
            confirmation = .resetFinal
        }) { destination in
            switch destination {
            case .help: CustomsCertificateHelpView(vm: vm)
            case .resetWarning: resetWarningSheet
            }
        }
        .onAppear { vm.refreshCertificateStatus() }
        .alert(confirmation?.title ?? "证书操作", isPresented: confirmationPresented, presenting: confirmation) { action in
            confirmationButtons(action)
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    private func certificateDetails(_ info: CustomsCertificateInfo) -> some View {
        GroupBox("当前 CA · 公钥证书") {
            VStack(alignment: .leading, spacing: 12) {
                detail("主题", value: info.subject)
                detail("序列号", value: info.serialNumber, monospaced: true)
                detail("有效期起", value: info.validFrom.formatted(date: .abbreviated, time: .standard))
                detail("有效期止", value: info.validUntil.formatted(date: .abbreviated, time: .standard))
                if info.validUntil <= Date() || info.validFrom > Date() {
                    notice("证书不在有效期内，请检查系统时间；需要更换 CA 时先停止代理和下载，再重置并重新安装。", symbol: "calendar.badge.exclamationmark", color: .orange)
                }
                Divider()
                HStack {
                    Text("SHA-256 指纹").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("复制指纹", action: vm.copyCertificateFingerprint).disabled(vm.certificateBusy)
                }
                Text(info.sha256Fingerprint)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("手机上的证书指纹必须与此 Mac 页面一致。不要仅凭证书名称判断，也不要仅相信下载页面给出的指纹。")
                    .font(.caption).foregroundStyle(.secondary)
                detail("公钥证书路径", value: info.certificatePath, monospaced: true)
                HStack {
                    Button("导出公钥证书…", action: vm.revealCertificate)
                    Button("在钥匙串中管理…", action: vm.openCertificateInKeychain)
                }.disabled(vm.certificateBusy)
                Text("导出使用保存对话框，仅导出公钥，不导出私钥。钥匙串按钮仅打开手动管理入口，不自动修改系统安全设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trustControls(_ info: CustomsCertificateInfo) -> some View {
        GroupBox("本机证书与信任") {
            VStack(alignment: .leading, spacing: 12) {
                Label(info.isTrusted ? "本机当前用户 SSL 校验：已信任" : "本机当前用户 SSL 校验：未信任",
                      systemImage: info.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(info.isTrusted ? Color.green : Color.orange)
                    .font(.headline)
                Text("此结果只针对这台 Mac 的当前用户，不代表 iPhone、Android 或其他用户已信任；也不保证所有 App 接受用户 CA。刷新失败时以错误提示为准。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Label(info.userTrusted ? "用户域信任设置：存在" : "用户域信任设置：未设置",
                          systemImage: info.userTrusted ? "doc.text" : "circle")
                    Label(info.adminTrusted ? "管理员域设置：存在" : "管理员域设置：未设置",
                          systemImage: info.adminTrusted ? "doc.text" : "circle")
                }.font(.caption)
                Text("设置存在不等于已信任：可能包含拒绝（deny）或未指定（unspecified）设置。是否有效信任请以上方本机当前用户 SSL 校验结果为准。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("安装并信任（当前用户）…") { request(.install) }
                    Button("撤销当前用户信任…") { request(.removeTrust) }
                    Spacer()
                    Button("重置 CA…", role: .destructive) { request(.resetWarning) }
                        .disabled(resetLocked)
                }.disabled(vm.certificateBusy)
                Text("安装仅在主动确认后进行：当前用户登录钥匙串 + 用户域 SSL 根信任；不是所有用户的系统信任。撤销不删除其他管理员域信任，也不会远程移除手机证书。")
                    .font(.caption).foregroundStyle(.secondary)
                if info.adminTrusted {
                    notice("重置已锁定：管理员域存在显式设置（不一定是信任）。请先在钥匙串中按指纹手动移除该管理员域设置，再刷新状态；应用不会自动撤销它。", symbol: "lock", color: .orange)
                }
                if proxyActive || vm.downloadSession != nil {
                    notice("重置已锁定：请先停止代理与临时下载。不会为重置默默停止正在运行的代理。", symbol: "lock", color: .orange)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var phoneSharing: some View {
        GroupBox("手机配置 · 临时公钥下载") {
            VStack(alignment: .leading, spacing: 12) {
                Text("手机与 Mac 连接同一受信任局域网，扫码使用 Safari / 浏览器下载 DER 公钥证书；安装与信任仍需在手机设置中手动完成。")
                    .foregroundStyle(.secondary)
                phoneProxyAddresses
                if let session = vm.downloadSession {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 8) {
                            if context.date < session.expiresAt {
                                HStack {
                                    Label("临时分享已开启", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
                                    Spacer()
                                    Text("剩余 \(remaining(until: session.expiresAt, now: context.date))").monospacedDigit()
                                }
                            } else {
                                Text("分享已到期 · 下载链接不可继续使用").foregroundStyle(.orange)
                            }
                            Text("独立随机端口：\(session.port) · 到期：\(session.expiresAt.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                            if context.date < session.expiresAt {
                                downloadLinks(session)
                            }
                        }
                    }
                    Text("停止不撤销已下载证书。撤销本机信任或重置 CA 时，下载由服务停止；重置前请先手动停止当前分享。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button { request(.share) } label: {
                        Label("开启 10 分钟临时分享…", systemImage: "qrcode")
                    }.disabled(vm.certificateInfo == nil || vm.certificateBusy)
                }
                Button("立即停止临时分享（含待启动下载）", role: .destructive, action: vm.stopCertificateDownload)
                notice("二维码是 HTTP 公钥下载地址，不是代理配置，也不包含私钥。分享端口与代理端口不同；防火墙可能需要允许入站连接。不会自动开启代理 LAN 或任何设备的系统信任。", symbol: "info.circle", color: .secondary)
                Button("查看 iOS / Android 安装步骤与排障") { sheet = .help }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var phoneProxyAddresses: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手机代理候选地址 · 代理端口 \(vm.portText)").font(.subheadline.weight(.semibold))
            if vm.localProxyAddresses.isEmpty {
                Text("未找到可用 IP，请连接局域网后刷新状态。").foregroundStyle(.orange)
            } else {
                ForEach(vm.localProxyAddresses, id: \.self) { address in
                    Text(address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            if !vm.listenOnLAN {
                Text("当前未允许代理 LAN：这些只是候选地址，手机暂不能通过它们使用代理。请先停止代理，在设置允许 LAN 后重启；证书下载能打开不代表代理已允许 LAN。")
                    .font(.caption).foregroundStyle(.orange)
            } else if !vm.isRunning {
                Text("代理\(vm.isStarting ? "正在启动" : "尚未运行")，请等待启动完成后连接。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("手机填写可达 Mac 的 IP 和上方代理端口，不填写证书分享的随机端口。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resetWarningSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("重置 CA · 第一步风险确认", systemImage: "exclamationmark.shield")
                .font(.title2.weight(.semibold)).foregroundStyle(.orange)
            ScrollView {
                Text(confirmationMessage(.resetWarning))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if resetLocked || !sameCertificate {
                Text("当前状态已变化或重置被锁定。请取消并返回管理页刷新；先停止代理 / 下载并清理管理员域设置。")
                    .font(.callout).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("取消", role: .cancel) {
                    awaitingResetConfirmation = false
                    sheet = nil
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("已了解，继续最终确认…", role: .destructive) {
                    guard !resetLocked, sameCertificate else { return }
                    awaitingResetConfirmation = true
                    sheet = nil
                }.disabled(resetLocked || !sameCertificate)
            }
        }
        .padding(24).frame(width: 600, height: 420)
    }

    private func downloadLinks(_ session: CustomsCertificateDownloadSession) -> some View {
        let url = session.urls.contains(selectedURL) ? selectedURL : (session.urls.first ?? "")
        return VStack(alignment: .leading, spacing: 10) {
            if !session.urls.isEmpty {
                Picker("下载地址（选择手机可达的 Mac 网卡）", selection: Binding(
                    get: { url }, set: { selectedURL = $0 }
                )) {
                    ForEach(session.urls, id: \.self) { value in Text(value).tag(value) }
                }
                HStack(alignment: .top, spacing: 18) {
                    CustomsCertificateQRCode(url: url)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(url).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("复制下载链接") { vm.copyCertificateDownloadURL(url) }
                        Text("会话证书 SHA-256（请与上方 Mac CA 指纹核对）").font(.caption).foregroundStyle(.secondary)
                        Text(session.fingerprint ?? "—").font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("未找到可分享的局域网地址。请检查网络接口或停止后重新开启分享。").foregroundStyle(.orange)
            }
        }
    }

    private func request(_ action: Confirmation) {
        confirmedFingerprint = vm.certificateInfo?.sha256Fingerprint ?? ""
        if case .resetWarning = action {
            awaitingResetConfirmation = false
            sheet = .resetWarning
        } else {
            confirmation = action
        }
    }

    @ViewBuilder
    private func confirmationButtons(_ action: Confirmation) -> some View {
        Button("取消", role: .cancel) { }
        switch action {
        case .install:
            Button("确认安装并信任", role: .destructive) {
                guard !vm.certificateBusy, sameCertificate else { return }
                vm.installCertificate()
            }
        case .removeTrust:
            Button("确认撤销用户信任", role: .destructive) {
                guard !vm.certificateBusy, sameCertificate else { return }
                vm.removeCertificateTrust()
            }
        case .resetWarning:
            Button("继续确认重置", role: .destructive) {
                guard !resetLocked, sameCertificate else { return }
                sheet = .resetWarning
            }
        case .resetFinal:
            Button("重置 CA", role: .destructive) {
                guard !resetLocked, sameCertificate else { return }
                vm.resetCertificate()
            }
        case .share:
            Button("确认开启临时分享") {
                guard !vm.certificateBusy, sameCertificate, vm.downloadSession == nil else { return }
                vm.startCertificateDownload()
            }
        }
    }

    private func confirmationMessage(_ action: Confirmation) -> String {
        let fingerprint = confirmedFingerprint.isEmpty
            ? "\n\n当前 CA 指纹无法读取：损坏 / 不完整的旧 DER 无法可靠识别，不会自动删除旧信任。请在钥匙串中核对现存证书指纹，手动清理旧证书与设置；管理员域设置须先移除。"
            : "\n\n请核对当前 CA 的 SHA-256：\n\(confirmedFingerprint)"
        switch action {
        case .install:
            return "将公钥证书安装到当前用户登录钥匙串，并在当前用户域设置 SSL 根信任。此 CA 能签发任何域名的证书，仅用于受控调试。在本应用确认框中取消不会执行安装。确认后系统可能要求身份授权；若在系统授权阶段取消或失败，可能已部分安装，请刷新状态并按需清理。不会修改所有用户的系统信任，也不会自动设置代理或安装手机证书。" + fingerprint
        case .removeTrust:
            return "仅撤销当前用户域对此 CA 的信任，并停止临时下载。不会撤销管理员域或组织策略的信任，因此本机仍可能显示已信任；手机已安装的证书必须手动移除。即使没有用户域信任设置，也可清理精确匹配的登录钥匙串证书；没有匹配项时无须修改。请随后刷新状态。" + fingerprint
        case .resetWarning:
            return "将更换当前 CA 身份及私钥，旧设备的证书不会因此自动移除。所有调试设备都需要重新下载、核对并安装新 CA，删除旧证书和旧信任。请先停止代理与临时下载；此操作不会偷偷停止代理。" + fingerprint
        case .resetFinal:
            return "此操作不可撤销。旧 CA 签发的证书不能再用于新一轮解密；所有设备须重新安装新的 CA。确认已停止代理与下载，并已准备清理旧证书、信任与相关连接缓存。" + fingerprint
        case .share:
            return "同一局域网中持有随机链接的设备可下载 CA 的 DER 公钥证书，绝不提供私钥。独立随机端口可能需要防火墙放行；不要在公网或不受信任网络分享。10 分钟后自动停止，也可随时手动停止。关闭管理页不会立即停止。不会自动开启代理 LAN、系统代理或证书信任。手机安装前必须从此 Mac 核对 SHA-256。" + fingerprint
        }
    }

    private func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(end.timeIntervalSince(now))))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func detail(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            Text(value).font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.callout).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct CustomsCertificateQRCode: View {
    let url: String
    @State private var image: NSImage?

    var body: some View {
        VStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    .padding(12).background(.white)
                    .accessibilityLabel("临时公钥下载二维码；旁边提供可复制的完整链接")
            } else {
                Label("二维码不可用，请复制链接", systemImage: "qrcode")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 184, height: 184)
        .task(id: url) {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(url.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let cgImage = CIContext().createCGImage(output, from: output.extent) else {
                image = nil
                return
            }
            image = NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
        }
    }
}
