import SwiftUI

/// Native, searchable documentation. Reading this page never changes trust or proxy settings.
@MainActor
struct CustomsCertificateHelpView: View {
    @ObservedObject var vm: CustomsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedSection = "principles"

    private struct Article: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let paragraphs: [String]
    }

    private var filteredArticles: [Article] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.articles }
        return Self.articles.filter {
            ($0.title + " " + $0.paragraphs.joined(separator: " ")).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "book.closed").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("证书助手与连接指南").font(.title2.weight(.semibold))
                    Text("原理 · 安装 · 手机配置 · 安全边界 · 排障")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索：iOS、Android、指纹、CONNECT、撤销…", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("搜索说明文档")
                if !search.isEmpty {
                    Button("清除") { search = "" }
                }
                Text("\(filteredArticles.count) 个章节").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目录").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
                        ForEach(filteredArticles) { article in
                            Button { selectedSection = article.id } label: {
                                Label(article.title, systemImage: article.symbol)
                                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).contentShape(Rectangle())
                                    .background(selectedSection == article.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(10)
                }.frame(width: 220).background(Color(nsColor: .controlBackgroundColor))
                Divider()
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            connectionSummary
                            if filteredArticles.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("没有匹配的章节", systemImage: "magnifyingglass")
                                        .font(.headline)
                                    Text("试试“信任”“代理”“防火墙”或清除搜索查看完整指南。")
                                        .foregroundStyle(.secondary)
                                }.padding(.vertical, 20)
                            }
                            ForEach(filteredArticles) { article in
                                articleView(article).id(article.id)
                            }
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: selectedSection) { _, id in
                        withAnimation { reader.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: search) { _, _ in
                        if let first = filteredArticles.first {
                            selectedSection = first.id
                            reader.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
            Divider()
            Text("指南只提供说明，不自动打开系统安全设置或更改信任；安装、撤销、重置及分享均在证书管理中主动确认。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.frame(width: 960, height: 760)
    }

    private var connectionSummary: some View {
        GroupBox("当前工作区 · 配置参考") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("本机代理：\(vm.endpoint)").font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button("复制地址", action: vm.copyEndpoint)
                }
                Text("代理\(vm.isStarting ? "正在启动" : (vm.isRunning ? "运行中" : "已停止")) · LAN \(vm.listenOnLAN ? "已允许" : "未允许") · 配置端口 \(vm.portText)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("手机代理候选地址（IP:代理端口）").font(.subheadline.weight(.semibold))
                if vm.localProxyAddresses.isEmpty {
                    Text("未找到可用 IP，请连接局域网后在证书管理刷新状态。").foregroundStyle(.orange)
                } else {
                    ForEach(vm.localProxyAddresses, id: \.self) { address in
                        Text(address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if !vm.listenOnLAN {
                    Text("当前未允许代理 LAN，候选地址暂不可供手机使用代理。请先停止代理，在设置允许 LAN 后重启；下载分享是否可达与此独立。")
                        .font(.caption).foregroundStyle(.orange)
                } else if !vm.isRunning {
                    Text("代理尚未启动完成，候选地址不是已运行的服务承诺。").font(.caption).foregroundStyle(.orange)
                }
                Text("手机代理应填 Mac 的局域网 IP + 此代理端口，不能填 localhost / 127.0.0.1，也不能填证书下载的随机端口。")
                    .font(.callout).foregroundStyle(.orange)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func articleView(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(article.title, systemImage: article.symbol).font(.title3.weight(.semibold))
            ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).font(.callout).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Divider().padding(.top, 8)
        }
    }

    private static let articles: [Article] = [
        Article(id: "principles", title: "01 · CA 与两段 TLS", symbol: "lock.shield", paragraphs: [
            "CA 是本工具的调试根证书颁发机构。公钥证书包含身份、公钥、序列号和有效期，可以导出给受控设备安装；私钥用于签发域名证书，只应留在这台 Mac。公钥下载不等于私钥泄露，但信任这个根 CA 会允许它签发的域名证书通过校验，所以仍需谨慎。绝不要分享私钥、私钥文件或含私钥的备份。",
            "HTTPS 解密不是把端到端 TLS 原样透传：客户端 ⇄ 海关是一段 TLS，海关 ⇄ 真实服务器是另一段 TLS。海关为目标域名签发临时证书，客户端必须信任当前 CA；海关解密请求后向上游建立独立 TLS，再将响应返回客户端。代理因此能够看到所选域名的明文请求和响应。",
            "客户端信任调试 CA 不代表上游真实服务器可以使用坏证书。上游仍采用系统证书校验，不提供“忽略上游证书错误”的安全绕过。过期、域名不符、缺少中间证书或其他上游校验失败需在服务器 / 合法测试环境解决。",
            "本机根 CA 使用 RSA 2048 / SHA-256，生成时有效期为 3650 天；按目标域名签发的临时证书有效期为 7 天，实际日期以证书管理页为准。临时证书换新不要求设备重装 CA；只有根 CA 重置或更换后才需要重新安装。根 CA 临近过期时不会静默更换，应主动重置并重新配置设备。",
            "证书与私钥存放在当前用户的 ~/Library/Application Support/Kria/Customs/Certificates/。KriaCustomsCA.crt 是公钥证书，KriaCustomsCA.key 是签发用私钥；目录权限仅当前用户可访问（0700），文件仅当前用户可读写（0600）。导出和二维码仅提供 DER 公钥 .cer，不含私钥。不要将整个 Certificates 文件夹分享、上传或加入代码仓库。",
            "信任状态仅是本机当前用户的 SSL 校验结果，不是手机状态、不代表所有协议或所有用户，更不保证 App 会接受用户 CA。证书主题名称可重复；应比较完整 SHA-256 指纹来确认身份。"
        ]),
        Article(id: "boundaries", title: "02 · 修改范围与权限", symbol: "hand.raised", paragraphs: [
            "默认开启 HTTPS 解密与局域网设备连接，可在代理设置中关闭，已保存的开关选择会保留。代理仍需手动启动，LAN 请仅在受信任网络使用；不会因为打开页面、刷新状态或生成 CA 就默认安装或信任。只有你在“安装并信任（当前用户）”的确认弹窗主动同意后，才安装公钥到当前用户登录钥匙串，并设置当前用户域的 SSL 根信任。本应用确认框中取消不会执行安装；确认后系统可能要求身份授权，若在系统授权阶段取消或失败，可能已部分安装，请刷新状态并按需清理。不是向所有用户的系统钥匙串批量安装，也不是管理员域信任。",
            "海关不会自动配置或恢复 macOS 系统网络代理、Wi-Fi 代理、手机描述文件、手机完全信任或第三方 App 网络策略。不会自动打开系统安全设置。你点击“在钥匙串中管理…”才进入手动管理入口；若组织策略限制修改，请联系管理员，不要尝试规避策略。",
            "临时公钥分享与代理服务独立。开启分享不会自动开启代理 LAN、启动代理或设置系统信任。撤销当前用户信任不撤销管理员域 / 组织策略信任；如果该域仍信任此 CA，本机可能继续显示已信任。"
        ]),
        Article(id: "conditions", title: "03 · 抓包与解密条件", symbol: "checklist", paragraphs: [
            "看到请求需要：① 代理成功启动；② 客户端实际使用此 HTTP / HTTPS 代理；③ 网络可达；④ 正在录制。App 若忽略系统代理、走直接连接或其他网络通道，不会被自动抓取。暂停录制只停止新增记录，不会停止转发或 Header 改写。",
            "看到 HTTPS 明文还需要：① 设置中的“解密 HTTPS”保持开启（默认开启；如需修改，先停止代理）；② SSL 域名范围匹配目标域名；③ 客户端安装并信任当前 CA；④ App 允许这种信任；⑤ TLS 和应用协议在支持范围内。Mac 安装 CA 与手机安装 CA 是独立步骤。",
            "SSL 域名可用 api.example.com、*.example.com 或 *；逗号 / 换行分隔。建议只选有调试权限的域名，避免 * 广泛解密。未启用解密或不匹配范围时，HTTPS 只保留 CONNECT 隧道信息，不包含明文 HTTP 正文。信任 CA 本身不会打开解密开关或扩大域名范围。",
            "默认 swimlane 规则值为空，不会注入 Header。只有全局改写开启、规则启用且值非空时才注入；同名 Header 被覆盖，名称大小写不敏感。swimlane 预设不可删除，但可清空 / 禁用；报文边界及代理连接相关 Header 不允许改写。规则保存后对后续请求生效，配置中的监听与 HTTPS 参数应先停止代理再修改。"
        ]),
        Article(id: "mac", title: "04 · Mac 安装步骤", symbol: "desktopcomputer", paragraphs: [
            "1. 打开顶栏“证书管理”，或设置 → 证书与信任 → 打开证书管理。尚无 CA 时先停止代理并生成 CA。查看主题、有效期、序列号和完整 SHA-256 指纹；如元数据读取失败，先处理错误并刷新，不要将错误当作“未生成”。",
            "2. 点击“安装并信任（当前用户）…”，核对确认框中的指纹。确认自己有调试权限并理解根 CA 能签发任何域名，再主动安装；系统可能要求身份验证。在本应用确认框中取消不安装；系统授权阶段取消或失败可能留下部分安装结果，应刷新后按需清理。安装完成后刷新状态，检查本机当前用户 SSL 校验及用户域设置；设置存在可能是拒绝或未指定，不等于已信任，以上述 SSL 校验结果为准；读取失败时不要凭旧状态判断成功。",
            "3. 在设置确认 HTTPS 解密开启（默认开启），并指定最小 SSL 域名范围；修改前先停止代理，完成后启动代理。macOS 系统设置 → 网络 → 当前网络 → 详细信息 → 代理，手动启用网页代理（HTTP）和安全网页代理（HTTPS），主机填 127.0.0.1，端口填当前工作区端口（默认 8888）。系统版本不同，入口名称可能略有差异。",
            "4. 用遵循代理的浏览器访问有权限的测试域名，检查是否出现明文请求。若仅 CONNECT，按排障章节检查解密和域名范围。调试结束手动关闭系统代理再停止服务，否则网络应用可能因仍指向已停止的代理而无法联网。",
            "5. 需要公钥文件时点击“导出公钥证书…”，在保存对话框选择位置；不含私钥。需要查看登录钥匙串或其他域信任时点击手动钥匙串管理入口，按指纹查找证书。不要通过名称误改其他证书。"
        ]),
        Article(id: "sharing", title: "05 · 临时下载与二维码", symbol: "qrcode", paragraphs: [
            "1. Mac 和手机连接同一受信任局域网。证书管理 → 手机配置 → 开启 10 分钟临时分享，阅读确认后开启。服务只提供 CA 的 DER 公钥证书，不提供私钥；链接含随机会话令牌，知道链接的同网设备可能下载公钥。不要分享截图 / 链接到公共群，也不要把端口转发到公网。",
            "2. 下载使用独立随机端口，不是代理端口。多网卡时从地址选择器选手机可达的 Mac 地址；VPN、虚拟网卡或不同网段地址可能不可达。使用二维码或复制完整 URL（含令牌），不要手动删改路径。防火墙可能需要允许此应用的入站连接；分享不会自动改变代理 LAN 或系统代理。",
            "3. 二维码只是 HTTP 公钥下载，不是 Wi-Fi / 代理自动配置。HTTP 下载本身不提供服务器身份保证，安装前必须与这个 Mac 的证书管理页面核对完整 SHA-256，而不是仅相信下载页面或二维码旁的名称。不一致立即停止，不安装。",
            "4. 倒计时到期由应用的临时下载服务自动停止；页面到期后不再显示可用二维码。立即停止按钮可提前关闭下载。关闭管理页或帮助页不是立即取消分享，重新打开仍可管理未到期会话；应用退出后不应依赖链接继续可用。撤销本机用户信任会停止分享；重置前先手动停止下载。",
            "5. 停止分享只切断后续下载，不远程删除手机已下载 / 安装的证书，不撤销手机信任。完成安装后仍须单独配置手机代理和 Mac 的代理 LAN。"
        ]),
        Article(id: "ios", title: "06 · iPhone / iPad", symbol: "iphone", paragraphs: [
            "1. 在 Mac 开启临时分享，选择手机可达地址。iOS 使用 Safari 打开二维码对应的 HTTP 链接下载证书；若扫码默认在其他 App 内打开，复制链接到 Safari。出现描述文件下载提示后允许下载，不代表安装或完全信任已经完成。",
            "2. 设置 → 通用 → VPN 与设备管理（某些版本显示“已下载描述文件”），找到刚下载的证书描述文件，打开查看详情；核对 CA 身份，完整 SHA-256 应与 Mac 管理页一致。若系统详情不能完整展示该指纹，请先通过受信任方式核验下载证书，不要只按名称确认。按系统提示安装，可能需要设备密码。",
            "3. 设置 → 通用 → 关于本机 → 证书信任设置，手动开启这张根证书的完全信任并确认风险。安装描述文件 ≠ 开启完全信任：这是必须分别完成的两个步骤；Mac 显示已信任也不能代替 iPhone 的信任设置。请确认开关对应的是当前海关 CA，而非同名旧证书。受管理设备可能由 MDM 限制，入口与可用性以系统策略为准。",
            "4. Mac 设置确认“允许局域网设备连接”和“解密 HTTPS”开启（两项默认开启），并核对解密域名；如需修改，先停止代理，完成后启动代理。手机设置 → Wi-Fi → 当前网络详情 → HTTP 代理 → 手动，服务器填 Mac 的局域网 IP，端口填工作区代理端口。不要填 localhost、127.0.0.1 或证书分享随机端口。",
            "5. 在 Safari 访问测试域名验证；App 仍可能不使用代理或使用证书固定。若曾重置 CA，旧证书即使“完全信任”也不等于信任新 CA，需核对新指纹、删除旧描述文件并重新安装。结束后关闭该 Wi-Fi 的 HTTP 代理，按需要移除描述文件及旧 CA。"
        ]),
        Article(id: "android", title: "07 · Android", symbol: "smartphone", paragraphs: [
            "1. 使用手机浏览器打开临时下载链接，核对公钥证书指纹与 Mac 完整 SHA-256。设置中的安装入口因厂商 / 版本不同，常在安全与隐私 → 更多安全设置 → 加密与凭据 → 安装证书 → CA 证书，或“从存储安装”。只安装到受控测试设备，阅读系统警告，可能需要锁屏凭据。",
            "2. Android 7+ 的许多 App 默认不信任用户安装的 CA。因此“安装成功”不代表第三方 App 能被解密。对于你自己开发的应用，可在你自己的 debug build 的 network_security_config 中显式允许调试用用户 CA，例如 debug-overrides 下设置证书来源为 user，并正确在调试 Manifest 关联配置。不要把调试信任配置带入 release。",
            "3. 这不是绕过第三方 SSL pinning 的方案，也不应改动第三方应用、设备安全策略或根证书库来强行解密。对你自己的 App，应通过经授权的调试构建和网络配置排查；组织策略受限请联系管理员。",
            "4. Mac 确认开启代理 LAN 后，手机当前 Wi-Fi → 编辑 / 高级选项 → 代理 → 手动，主机填 Mac 局域网 IP，端口填代理端口。不同系统入口不同；需要浏览器 / App 实际使用此代理。调试结束关闭 Wi-Fi 代理，在用户凭据 / 证书页面按指纹移除这张 CA。"
        ]),
        Article(id: "cleanup", title: "08 · 撤销、重置与清理", symbol: "trash", paragraphs: [
            "撤销当前用户信任：在证书管理主动确认，撤销此 Mac 当前用户域的 SSL 信任并停止临时分享。即使没有显式用户域设置，也可清理精确匹配的登录钥匙串证书；无匹配项时无需修改。不自动撤销管理员域 / 组织策略信任，也不替其他用户或手机删除证书。若刷新仍显示已信任，检查管理员域提示，在有权限时使用钥匙串手动管理，必要时联系管理员。",
            "重置 CA：先停止代理，再立即停止临时下载。运行 / 启动中或存在下载会话时重置按钮锁定，不会默默关闭代理。管理员域存在显式设置（包含拒绝或未指定）时也会锁定，须先在钥匙串按指纹手动移除并刷新。重置先显示风险说明页，再弹最终确认，需两次确认且不可撤销，将更换 CA 身份及签发用私钥；旧设备需重新下载、核对新指纹并安装 / 信任新 CA。不要把重置当成普通刷新。",
            "损坏 / 不完整 CA：如果无法读取元数据，证书管理仍提供恢复重置入口。无法识别旧 DER 时，不会自动删除旧信任或旧证书；请在钥匙串中核对现存证书指纹并手动清理，管理员域设置须先移除。恢复后核对新 CA 指纹再安装，不要只凭名称清理。",
            "重置后在所有设备移除旧 CA / 描述文件和不再使用的信任。按需断开旧连接、重启测试 App / 浏览器以清理缓存的 TLS 会话，再重新验证。旧设备上的证书不会自动删除；Mac 用户域清理不能代替手机清理，也不能代替管理员域清理。",
            "结束调试建议顺序：手动关闭客户端系统 / Wi-Fi 代理 → 停止代理 → 停止公钥分享 → 按需要撤销 Mac 用户信任并移除手机 CA → 删除不需要的导出公钥和含敏感规则值的配置。不要删除其他业务证书。"
        ]),
        Article(id: "privacy", title: "09 · 数据隐私与限制", symbol: "eye.slash", paragraphs: [
            "抓包可能包含 Cookie、Authorization、密码、URL 查询参数与业务正文。仅调试有权限的设备和域名。请求 / 响应每侧最多预览 512 KiB，最多保留 1000 条，总正文预算 64 MiB，达到预算可提前淘汰旧记录。内容仅驻留内存，抓包正文不持久化，但截图、复制、外部工具与分享操作可能把内容带出应用。",
            "规则和配置会持久化。不要在 Header 规则保存令牌、Cookie 或密码。复制 cURL 可能带真实认证 Header、查询参数和正文；复制不会发请求，执行才会发请求，分享前应脱敏。仅完整且成功结束的 HTTP 请求支持完整 cURL；隧道、失败、截断与进行中记录不能保证完整重放。",
            "目前重点支持 HTTP/1.1（兼容 HTTP/1.0），不是完整 Charles 功能复刻。不承诺 HTTP/2、HTTP/3 或 WebSocket 帧抓包；客户端与服务端的协议需求不兼容可能失败。当前 TLS 解密采用 SecureTransport，按 TLS 1.2 的当前实现能力使用，不承诺 TLS 1.3 或所有密码套件 / 协议组合可用。",
            "gzip / deflate 只在后台用于正文展示解压，不改写实际 wire 字节和 Headers；解压输出也最多 512 KiB。截断或解压异常会回退压缩字节 Hex。br / Brotli 暂不支持，二进制与非 UTF-8 不猜测编码。Raw 是当前展示数据的未格式化文本，Pretty JSON 仅调整有效完整 JSON 的展示，并不改写网络响应。"
        ]),
        Article(id: "faq", title: "10 · 常见问题（13 问）", symbol: "questionmark.bubble", paragraphs: [
            "Q1 · 完全没有记录？\n确认代理已启动、端口正确且在录制；先用遵循代理的浏览器测试。检查客户端代理、Mac LAN 开关、网络可达和防火墙。App 若绕过系统代理就不会出现，不代表证书出错。",
            "Q2 · 只看到 CONNECT，没有 HTTPS 正文？\n检查解密开关和 SSL 域名范围，停止代理修改后重新启动。仅安装 CA 不会自动开启解密；不匹配范围的 HTTPS 保持隧道。",
            "Q3 · 浏览器提示 TLS 不受信任？\n检查该设备安装并信任的是当前 CA，不只是名称相同；核对 SHA-256、有效期与设备时间。iOS 必须额外开启完全信任，Android App 可能不接受用户 CA。",
            "Q4 · Mac 显示已信任，手机却失败？\n本机状态不是手机状态。手机要独立安装、信任和配置代理；Mac 的登录钥匙串不会同步到手机。检查手机证书指纹与当前 Mac 一致。",
            "Q5 · upstream bad certificate / 上游证书校验失败？\n这是海关到真实服务器的 TLS 链路问题，检查真实域名、有效期、中间证书、系统时间、DNS 与合法网络环境。系统不会跳过上游校验；客户端安装调试 CA 不能修复上游坏证书。",
            "Q6 · 某个 App 有 SSL pinning，浏览器却正常？\nApp 可能固定证书 / 公钥，或根本不遵循代理。安装用户 CA 不会绕过证书固定。仅对自己有权限的 debug build 配置调试网络信任，不规避第三方固定或设备安全策略。",
            "Q7 · 刷新失败或安装被权限 / 策略拒绝？\n读取失败不应被当作未信任。查看独立错误提示，完成系统要求的授权后重试刷新；组织策略或受管理设备可限制信任修改，联系管理员。不要反复重置 CA 来绕过策略。",
            "Q8 · 手机打不开二维码 URL？\n确认分享未到期、完整 URL 令牌正确、手机与 Mac 同一可达网络，并选对网卡 IP。检查防火墙入站规则、访客 Wi-Fi 隔离、VPN 和跨网段路由。下载随机端口与代理端口独立，代理运行正常并不保证下载可达。",
            "Q9 · iOS 完全信任已开，换 CA 后仍失败？\n开关可能对应旧 CA。重置改变身份与指纹；移除旧描述文件，核对新指纹并重新安装、开启新 CA 的完全信任，断开旧连接后重试。",
            "Q10 · 撤销后本机仍显示已信任？\n撤销只影响当前用户域；管理员域或组织策略可能仍信任。刷新检查域状态，按权限手动管理或联系管理员。不会自动撤销其他域，更不会自动删除手机描述文件。",
            "Q11 · 关闭窗口后二维码还有效，或停止后手机仍信任？\n关闭管理 / 帮助页面不结束应用开启的 10 分钟分享，需手动停止或等到期。停止仅关闭下载，已安装证书仍在设备上，必须自行移除。链接不是永久服务。",
            "Q12 · 停止代理后无法联网，正文不全或无法复制 cURL？\n先关闭客户端系统 / Wi-Fi 代理，避免继续连接已停止的端口。正文受每侧 512 KiB、1000 条和 64 MiB 总预算限制；截断 / 失败 / 隧道记录不能完整重放。br、WebSocket 和超出当前 TLS / HTTP 支持范围的请求不承诺可读。",
            "Q13 · 部分 HTTPS 请求失败于客户端 TLS 握手（OSStatus -9806），Safari 提示“此连接非私人连接”？\n已确认案例：iPhone App 的部分 HTTPS 请求出现 connection closed via error，Safari 访问同一域名也提示非私人连接；调整设备证书信任配置后恢复。此场景应优先检查信任配置，而不是直接认定 App 有证书绑定或 HTTP 正文解析失败。",
            "处理顺序：① 在当前运行的海关证书管理页核对 CA 身份与完整 SHA-256 指纹，确认手机安装的不是同名旧 CA；② iPhone 设置 → 通用 → VPN 与设备管理，确认已安装对应证书描述文件；③ 设置 → 通用 → 关于本机 → 证书信任设置，开启当前 CA 的完全信任并确认风险；④ 保持同一代理配置，用 Safari 重新访问同一 HTTPS 域名，海关出现解密后的 GET 记录即表示该次握手成功，404 或登录页也可作为握手验证；然后回到 App 重新发起请求。已有失败记录不会因修改信任而补出正文。",
            "判断边界：-9806 仅表示 TLS 连接异常关闭，不能单凭错误码确认信任问题。本案例通过修正信任配置验证了原因。若 Safari 仍警告，请查看证书详情、有效期和设备时间，不要忽略安全警告继续访问，也不要盲目重置 CA。若 Safari 能解密而 App 仍失败，再检查 App 的自定义信任校验、证书绑定及协议兼容性；CONNECT 的 200 只表示接受隧道，不代表 HTTPS 请求成功。"
        ])
    ]
}
