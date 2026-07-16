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

CC3 可以看成 CC1 LazyMap 链的后半段替换版。前半段仍然复用 CC1 的触发能力，变化点在执行手段和最终落点。

## 1. 修补限制了单步调用能力

这个变化不是平空出现的，而是发生在 CC1 已经被针对之后。外部防护和组件官方修补，分别从两个位置压缩了 CC1 的可用面。

第一类是第三方过滤器，代表是 `SerialKiller`。它不是 Apache 官方组件，而是 `ikkisoft` / Luca Carettoni 维护的反序列化过滤库。它的思路不是理解整条 gadget 链，而是在 `ObjectInputStream.resolveClass()` 阶段先看“即将被反序列化的类名”，再用黑白名单决定是否放行。这个位置很关键，因为它拦截的不是 `readObject()` 里的某个具体动作，而是“这个类能不能进入反序列化流”。在早期配置里，它直接把 `InvokerTransformer` 放进黑名单；后续又把 `InstantiateTransformer` 也加入进去。

第二类是 Apache Commons Collections 自己的官方修补。`3.2.2` 发布于 **2015 年 11 月 15 日**，开始对一批 unsafe functor 的序列化与反序列化做默认限制；`4.1` 则更进一步，直接让这些 unsafe 类不再实现 `Serializable`。这两步的区别很重要：前者是“类还在，但默认不让它通过序列化边界”，后者是“从类型层面切掉这条入口”。

限制大致落在三个位置：

```text
SerialKiller 这类过滤器拦的是：
  某个类名能不能进入反序列化流

Commons Collections 3.2.2 拦的是：
  这些 unsafe functor 能不能继续参与序列化 / 反序列化

Commons Collections 4.1 拦的是：
  这些 unsafe functor 是否还具备 Serializable 入口
```

对 CC1 来说，真正被压缩的是后半段的执行方式：

```text
InvokerTransformer
 -> Method.invoke()
 -> Runtime.exec()
```

也就是说，被重点限制的是“单步方法调用”这一段，而不是整条链里所有组件都失效了。前半段的这些能力并没有同时消失：

```text
readObject() 仍然能带起调用
LazyMap.get() 仍然能触发 transform()
ChainedTransformer 仍然能串接别的执行组件
```

对应出处：

- [SerialKiller.java](https://github.com/ikkisoft/SerialKiller/blob/4a09d4ad03e9e9535656ef7c55f9be0c046082b1/src/main/java/org/nibblesec/tools/SerialKiller.java#L40-L109)
- [3ce0fe5 serialkiller.conf](https://github.com/ikkisoft/SerialKiller/blob/3ce0fe5/config/serialkiller.conf#L5-L15)
- [Apache Commons Collections Security Vulnerabilities](https://commons.apache.org/proper/commons-collections/security.html)
- [Commons Collections 3.2.2 release notes](https://commons.apache.org/proper/commons-collections/changes.html#Release_3.2.2_%E2%80%93_2015-11-15)
- [Commons Collections 4.1 release notes](https://commons.apache.org/proper/commons-collections/release_4_1.html)

## 2. 链上还保留着入口、触发和串联能力

`InvokerTransformer` 被重点限制之后，链子并没有整体失效。CC3 能成立，靠的是前半段这些能力还在。

ysoserial 的 `CommonsCollections3` 注释直接说明了这一点：

```text
Variation on CommonsCollections1 that uses InstantiateTransformer instead of
InvokerTransformer.
```

出处：[ysoserial CommonsCollections3.java](https://github.com/frohoff/ysoserial/blob/master/src/main/java/ysoserial/payloads/CommonsCollections3.java#L26-L28)

入口本身没有变化，仍然发生在反序列化阶段：

```text
ObjectInputStream.readObject()
 -> AnnotationInvocationHandler.readObject()
```

入口之后的调用过程也基本复用 CC1：

```text
AnnotationInvocationHandler.readObject()
 -> proxyMap.entrySet()
 -> inner AnnotationInvocationHandler.invoke()
 -> LazyMap.get("entrySet")
 -> ChainedTransformer.transform(...)
```

这一段提供了三类能力：

- 入口能力：`readObject()` 仍然能带起 `AnnotationInvocationHandler.readObject()`
- 触发能力：`Map` 调用仍然能被送进 `LazyMap.get()`
- 串联能力：`ChainedTransformer` 仍然能继续串联后半段组件

参与这一段的主要类是：

| 类 | 作用 |
|------|------|
| `AnnotationInvocationHandler` | 反序列化时带起 `entrySet()` |
| `Proxy` / `InvocationHandler` | 把普通 `Map` 调用转给内层 handler |
| `LazyMap` | 在 key 不存在时触发 `transform()` |
| `ChainedTransformer` | 串接后半段执行组件 |

---

## 3. 链的后半段缺少继续推进调用的能力

前半段还能把调用送进 `ChainedTransformer`，但调用送到这里并不会自己继续往前走。CC1 原来的后半段，依赖的是一组连续的单步方法调用：

```text
InvokerTransformer("getMethod")
 -> InvokerTransformer("invoke")
 -> InvokerTransformer("exec")
```

关键不只是最后落到 `Runtime.exec()`，而是这组调用本身提供了一种推进能力：

```text
拿到一个对象
 -> 调它的方法
 -> 取回返回值
 -> 再把返回值交给下一步
```

`InvokerTransformer` 被限制之后，链子的缺口就出现在这里。后半段缺少的，不是入口，不是触发，也不是最终落点，而是这种把调用一层层继续往前送的能力。

---

## 4. 可控 bytecode 加载成为新的执行方向

单步方法调用这条路被压缩之后，后半段就不能再沿着 `Method.invoke() -> Runtime.exec()` 继续走了。这时“执行”本身也需要换一种理解方式。

对 Java 来说，代码执行不只有命令执行这一种表现。只要能把可控 bytecode 送进类加载流程，再让 JVM 完成类定义、类初始化或者实例化，外部数据同样会转成执行效果：

```text
把可控 bytecode 送进某个类
 -> 触发类加载
 -> 触发 defineClass / newInstance
 -> 在类初始化 / 实例化阶段执行代码
```

后半段需要补上的能力也就具体了：

```text
1. 还能接在 Transformer 体系后面
2. 不再依赖 InvokerTransformer 这种单步方法调用
3. 能把调用送到可控 bytecode 的加载位置
```

后面关注的重点，也就不再是 `Runtime.exec()`，而是哪些组件能把调用推进到类加载型落点。

---

## 5. 替代组件开始收敛出来

执行方向改成类加载之后，后半段要补的其实是三块能力：

```text
1. 谁把“某个 Class”变成一次构造调用
2. 谁让这次构造调用自带副作用，继续往前推进
3. 谁在后面把这次调用继续串联到 defineClass
```

CC3 里的几个关键类，就是沿着这三块能力逐步收敛出来的。

`InstantiateTransformer` 先补上第一块能力。它的核心能力就是调用构造函数：

```java
Constructor con = ((Class) input).getConstructor(iParamTypes);
return con.newInstance(iArgs);
```

出处：`commons-collections-3.2.1-sources.jar` 中的 `InstantiateTransformer.java`

它适合作为 CC3 的第一步，原因很直接：

```text
它可以把 ChainedTransformer 的输出从“某个 Class”
直接变成“调用这个类的构造函数”
```

但只会“调用构造函数”还不够。还需要这个构造函数本身带着可继续推进的副作用，否则调用会停在这里。

第二块能力落在 `TrAXFilter` 上。`InstantiateTransformer` 只能负责调用构造函数，还需要一个“构造函数本身有副作用”的类。

它的构造函数如下：

```java
public TrAXFilter(Templates templates) throws TransformerConfigurationException {
    _templates = templates;
    _transformer = (TransformerImpl) templates.newTransformer();
    _transformerHandler = new TransformerHandlerImpl(_transformer);
    _overrideDefaultParser = _transformer.overrideDefaultParser();
}
```

源码链接：[TrAXFilter.java](https://github.com/JetBrains/jdk8u_jaxp/blob/master/src/com/sun/org/apache/xalan/internal/xsltc/trax/TrAXFilter.java#L581-L595)

在 CC3 里，这一段可以组装成：

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

调用会继续进入：

```text
new TrAXFilter(templatesInstance)
 -> templatesInstance.newTransformer()
```

`InstantiateTransformer` 和 `TrAXFilter` 配合之后，调用已经到了 `templatesInstance.newTransformer()`。第三块能力就落在 `TemplatesImpl` 上了。`TemplatesImpl` 是 Xalan 中保存和加载 translet 的类。正常情况下，它保存的是 XSLT 编译后的 bytecode，后续通过 `newTransformer()` 加载并实例化。

CC3 借用的，正是它在 `newTransformer()` 过程中定义并实例化 translet 类的能力。

要让 `templatesInstance.newTransformer()` 继续走到类定义，这个对象至少要具备三块状态：

```java
TemplatesImpl templatesInstance = new TemplatesImpl();

setField(templatesInstance, "_name", "cc3");
setField(templatesInstance, "_bytecodes", new byte[][]{classBytes});
setField(templatesInstance, "_tfactory", new TransformerFactoryImpl());
```

ysoserial 中的对应代码：

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

三个字段分别负责：

| 字段 | 作用 |
|------|------|
| `_bytecodes` | 保存待加载的 translet class bytes |
| `_name` | 让 `TemplatesImpl` 处于可用模板状态 |
| `_tfactory` | 提供 transformer 和类加载所需的工厂上下文 |

作为 `_bytecodes` 放进去的类，通常还需要继承 `AbstractTranslet`：

```java
public class Evil extends AbstractTranslet {
    static {
        // class initialization side effect
    }

    public void transform(...) {}
    public void transform(...) {}
}
```

因为 `TemplatesImpl` 在加载 `_bytecodes` 之后，需要识别主 translet 类。继承 `AbstractTranslet` 是为了满足这个结构要求。

OpenJDK 中，`TemplatesImpl.newTransformer()` 会进入：

```java
transformer = new TransformerImpl(getTransletInstance(), _outputProperties, _indentNumber, _tfactory);
```

`getTransletInstance()` 继续触发：

```java
if (_name == null) return null;
if (_class == null) defineTransletClasses();
AbstractTranslet translet = (AbstractTranslet) _class[_transletIndex].newInstance();
translet.setTemplates(this);
```

`defineTransletClasses()` 的关键语句：

```java
_class[i] = loader.defineClass(_bytecodes[i]);
```

出处：[TemplatesImpl.java](https://github.com/openjdk/jdk8u/blob/master/jaxp/src/com/sun/org/apache/xalan/internal/xsltc/trax/TemplatesImpl.java#L390-L486)

这段调用压缩后是：

```text
TemplatesImpl.newTransformer()
 -> getTransletInstance()
 -> defineTransletClasses()
 -> ClassLoader#defineClass(_bytecodes)
 -> newInstance()
```

`defineClass` 负责把 `byte[]` 定义成 `Class`。后面的 `newInstance()` 会触发类初始化，因此 payload 中的 `static {}` 会执行。

---

## 6. CC3 由此重新成立

把前面的入口、触发过程、执行手段、最终落点接起来，CC3 完整链路就是：

```text
readObject()
 -> AnnotationInvocationHandler
 -> proxyMap.entrySet()
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

CC1 和 CC3 的后半段，对比起来就是：

```text
CC1:
InvokerTransformer
 -> Runtime.exec()

CC3:
InstantiateTransformer
 -> TrAXFilter(templatesInstance)
 -> TemplatesImpl.newTransformer()
 -> ClassLoader#defineClass(_bytecodes)
```

> CC3 保留 CC1 的入口和触发过程，把执行手段从 `InvokerTransformer` 换成 `InstantiateTransformer + TrAXFilter`，把最终落点切到 `TemplatesImpl#defineClass`。
