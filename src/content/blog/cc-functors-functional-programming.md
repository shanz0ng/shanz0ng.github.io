---
pubDatetime: 2026-06-24
title: "三块积木，一把枪——CC 组件里的函数式编程"
postSlug: cc-functors-functional-programming
featured: false
draft: false
tags:
  - Java
  - 代码审计
  - 反序列化
  - Commons Collections
  - 函数式编程
description: "从函数式编程的视角重新审视 Commons Collections 的 functor 体系：ConstantTransformer、InvokerTransformer、ChainedTransformer 三块积木如何被组合成 CC1 攻击链，以及 TransformedMap.setValue() 为何成为扳机。"
---

# 三块积木，一把枪——CC 组件里的函数式编程

---

## 一、背景：2004 年，CC 开发者想在 Java 里实现函数式编程

2000 年代初，Java 没有泛型，没有 lambda，没有 `java.util.function`。而当时 Haskell、Lisp、Erlang、Scala 早已把函数式编程做得很成熟。

CC 设计者用了三年、分两个阶段搭出这套体系：

| 版本 | 年份 | 内容 |
|------|------|------|
| CC 1.0 | ~2001 | `Transformer`、`Predicate`、`Closure` 三个 functor 接口 |
| CC 2.1 | ~2002 | `Factory` 接口 |
| CC 3.0 | 2004年6月 | `ConstantTransformer`、`InvokerTransformer`、`ChainedTransformer` 等 40+ 个实现类 |

先定接口，再写实现——三年后才有了完整的 functor 体系。

Apache Commons 的开发者想给 Java 也加上这种函数式编程的能力。但 Java 里没有"函数"这种类型，他们只能用**接口**来模拟函数。他们定义了四个核心接口：

| 接口 | 方法签名 | 十年后 Java 8 的对应 |
|------|---------|---------------------|
| `Transformer` | `Object transform(Object input)` | `Function<T, R>` |
| `Predicate` | `boolean evaluate(Object obj)` | `Predicate<T>` |
| `Closure` | `void execute(Object input)` | `Consumer<T>` |
| `Factory` | `Object create()` | `Supplier<T>` |

实现类放在 `org.apache.commons.collections.functors` 包下——"functor" 是函数式编程术语，意思是"可以像函数一样被调用的对象"。

CC 3.0 源码中，四个接口的 Javadoc 第一句话都写了

 `Defines a functor interface`（定义一个 functor 接口）：

```java
// Transformer.java
/** Defines a functor interface implemented by classes that
    transform one object into another. */

// Predicate.java
/** Defines a functor interface implemented by classes that
    perform a predicate test on an object. */

// Closure.java
/** Defines a functor interface implemented by classes that
    do something. */

// Factory.java
/** Defines a functor interface implemented by classes that
    create objects. */
```

其中有三块最基础的积木，构成了函数式编程的核心：

| 数学公式 | CC 实现类 |
|----------|-----------|
| `f(x) = c`（常量函数） | `ConstantTransformer` |
| `f(x) = x.m(a)`（对输入调用方法） | `InvokerTransformer` |
| `f(x) = f₃(f₂(f₁(x)))`（函数复合） | `ChainedTransformer` |

`ConstantTransformer` 的存在本身就是证据——一个只做集合回调的库，不需要常量函数。十年后 Java 8 发布，`java.util.function` 包用几乎相同的概念体系验证了这个方向的正确性。

## 二、函数式编程是什么

理解函数式编程，抓住三个词就够了：值、参数、管道。

函数式编程，就是把"做什么"从代码里拆出来，变成可传递的积木。放到变量里是值，传给方法是参数，头尾接起来是管道。

这个概念比 Java 老得多——它的数学根基可以追溯到 1930 年代——数学家阿隆佐·丘奇提出了 λ 演算（lambda calculus），
核心思想就是把"计算"表达成 f(x)：

```
f(x) = x² + 1    ← 我们高中学的，输入 x，输出结果，不改任何外部状态
```

CC 的 Transformer，本质上就是这个 f(x)。

先看一条大家都非常熟悉的命令：

```bash
echo baidu.com | ./SubFinder/subfinder -silent | ./KsubDomain/ksubdomain -silent | ./HTTProbe/httprobe | ./HTTPX/httpx -title/-ip
```

它的作用是：从 baidu.com 出发，发现子域名，筛选存活的，加上 https://，提取页面标题。每一步是一个独立的工具，管道符把这些工具串成了流水线，上一个工具的输出是下一个工具的输入。

这条命令里藏着函数式编程的三个概念，拆开看——

### 1. 函数是值 `f(x) = c`

把"一个操作"赋给变量、存起来、随时用。

管道里的第一个命令 `echo baidu.com` 就是一个值——不管管道前面有没有输入，
它永远返回 `"baidu.com"`。在 CC 里这就是 F1：

```java
F1("baidu.com").transform(null);  // → "baidu.com"
```

### 2. 函数可以当参数传 `f(x) = x.m(a)`

把"一个操作"传给另一个方法，让它帮你执行。

`echo` 后面的 `subfinder`、`ksubdomain`、`httprobe`、`httpx`，每个都是一个被传进管道的函数。它不关心数据从哪来，只等待前面的输出进入自己的输入。每个等价于一次 `F2("方法名")`——反射调用，在输入上执行对应方法。

### 3. 函数可以串起来（复合）`f(x) = f₃(f₂(f₁(x)))`

前一步的输出 = 后一步的输入，形成流水线。整条管道就是函数复合：

```
f(baidu.com) = httpx(httprobe(ksubdomain(subfinder(baidu.com))))
//             f4(     f3(      f2(       f1(      x     ))))
```

管道符隔开的每个命令是一个函数，`ChainedTransformer` 就是 Java 里的管道符。

### CC 用 40+ 个类实现了这套体系
上面三类基础函数是积木，CC 的 functors 包里 40+ 个类都是它们的变体和组合。

---

## 三、把管道符翻译成 Java

三块积木单独看不出用处。拼在一起就是一条流水线——和 Linux 管道符一模一样：

```bash
echo baidu.com | ./SubFinder/subfinder -silent | ./KsubDomain/ksubdomain -silent | ./HTTProbe/httprobe | ./HTTPX/httpx -title/-ip
```

每条命令是一个函数，管道符把前一个输出喂给后一个输入：

```
echo baidu.com  → F1("baidu.com")     = 常量函数，提供起始值
subfinder      → F2("subfinder")     = 反射调用方法
ksubdomain     → F2("ksubdomain")    = 反射调用方法
httprobe       → F2("httprobe")      = 反射调用方法
httpx          → F2("httpx")         = 反射调用方法
整条管道        → F3([F1,F2,F2,F2,F2]) = 函数复合
```
三个积木的定义：

```java
// F1：f(x) = c — 不管输入是什么，永远返回固定值
static Transformer F1(Object constant) {
    return new ConstantTransformer(constant);
}

// F2：f(x) = x.m(a) — 在输入上反射调用方法
static Transformer F2(String method, Class[] types, Object[] args) {
    return new InvokerTransformer(method, types, args);
}

// F3：f(x) = f₃(f₂(f₁(x))) — 把多个函数串成管道
static Transformer F3(Transformer[] transformers) {
    return new ChainedTransformer(transformers);
}
```

2004 年，Java 1.4 没有函数式编程，写法是这样的：

```java
// 2004 年，没有泛型，没有方法链，每步一个中间变量
String domain = "baidu.com";
List subs = SubFinder.getSubdomains(domain);
List alive = KsubDomain.filterAlive(subs);
List urls = HttpProbe.addHttps(alive);
List results = HttpX.extractTitles(urls);
```

CC 提供了 F1、F2、F3 三块积木——当你把每一步包成 `Transformer`，`ChainedTransformer` 替你管数据流，你不用手写中间变量了。
## 四、设计者没预料到的用法

F1、F2、F3 是通用积木。设计者没有限制你能传什么参数——函数式编程本来就不该限制。

但攻击者发现：**一模一样的三块积木，把参数换掉，就能执行任意代码。**

```
设计者往管道里装的：            攻击者往管道里装的：
─────────────────────          ─────────────────────
F1("baidu.com")                F1(Runtime.class)
F2("subfinder")                F2("getMethod", [String,Class[]], ["getRuntime",null])
F2("ksubdomain")               F2("invoke",    [Object,Object[]], [null,null])
F2("httprobe")                 F2("exec",      [String],          ["calc"])
F2("httpx")

F3 管道 = 一模一样，没变
```
```java
// 还是那F1、F2、F3 三块积木
static Transformer F4() {
    return F3(new Transformer[]{
        F1(Runtime.class),
        F2("getMethod", new Class[]{String.class, Class[].class},
           new Object[]{"getRuntime", null}),
        F2("invoke", new Class[]{Object.class, Object[].class},
           new Object[]{null, null}),
        F2("exec", new Class[]{String.class},
           new Object[]{"calc"})
    });
}
F4().transform(null);  // calc 弹出
```
**这不是后门。** API 没变，设计意图没变。变的是传进去的参数。设计者造了积木，攻击者用这些积木搭了一把枪。

---

## 五、设计深度：为什么 setValue 会成为扳机

上面那条链，是我们自己手动调用 `transform()` 才跑起来的。

但真正的反序列化攻击不能指望手工点火——必须有一个反序列化过程中自动触发的入口，帮你调用到那条链。

到这里只差一个问题：**谁在反序列化时帮你调了 `transform()`？**

### Map 的两个写入入口：`put()` 和 `setValue()`

往 Map 里写值，直觉上就是 `map.put(key, value)`。但 Map 还有第二个写入入口：

```java
map.entrySet().iterator().next().setValue(newValue);
```

拿到 `Map.Entry` 之后可以直接改值，完全绕过 `put()`。只拦 put 不拦 setValue，就像装了防盗门却没锁窗户——那条转换规则形同虚设。

解决办法很直接：`entrySet()` 不返回原始的 Entry，而是包一层带检查逻辑的 Entry 再给你。

核心代码可以浓缩成这样：

```java
public Object setValue(Object value) {
    value = parent.checkSetValue(value);
    return entry.setValue(value);
}
```

它的意思非常直接：

1. 先别把新值写回去
2. 先交给 `parent.checkSetValue(value)` 处理
3. 处理完，再真正写入底层 Map

这里的 `parent`，就是外层那个装饰器对象。

### 为什么这一步会连到 `transform()`？

因为在 `TransformedMap` 里，`checkSetValue()` 被重写成了下面这样：

```java
protected Object checkSetValue(Object value) {
    return valueTransformer.transform(value);
}
```

于是，整条路径就通了：

```text
entry.setValue(x)
   ↓
checkSetValue(x)
   ↓
valueTransformer.transform(x)
```

看到这里，标题里的问题就有答案了：

> **`setValue()` 会成为扳机，不是因为它特殊，而是因为 `TransformedMap` 必须保证连这条写入路径也会触发转换。**

### 这不是 bug，是完整的设计

站在组件作者视角，这套设计完全说得通。

他想解决的是"所有写入操作统一过一遍转换"的问题：  

无论你是 `put()`，还是先拿到 `Entry` 再 `setValue()`，只要你往这个 Map 里写数据，就都应该先过一遍转换逻辑。这样规则才一致。

从这个角度看，`TransformedMap` 不是写错了，只是考虑得比较全面。

如果愿意套设计模式的术语，这里其实就是模板方法模式：

- 父类规定流程：`setValue()` → `checkSetValue()` → 真正写入
- 子类决定细节：`checkSetValue()` 到底做什么
- `TransformedMap` 给出的具体答案是：调用 `Transformer`

### 这和攻击是怎么接上的？

攻击者关心的不是"这个设计优不优雅"，而是另一件事：

> 只要反序列化过程中，有人替我调用了 `entry.setValue()`，就等于替我触发了 `transform()`。


而 `AnnotationInvocationHandler.readObject()` 恰好会在反序列化时遍历 Map 的 entry，并在类型不匹配时调用 `entry.setValue()`——链路闭合。

CC1 真正微妙的地方在于：它利用的不是一个 bug，而是一个刻意留下的扩展点。`setValue()` 之所以会触发 `transform()`，正是因为设计者想保证"所有写入都经过转换"——这恰恰是 `TransformedMap` 的正确行为。

### 五个零件，一把枪

到这里，可以把整条链重新看成一把枪：


```
         ConstantTransformer = 子弹（Runtime.class）
         InvokerTransformer  = 火药（三节，getMethod → invoke → exec）
         ChainedTransformer  = 枪管（串联全部火药）
         TransformedMap      = 扳机（setValue → checkSetValue → transform）
         AnnotationInvocationHandler.readObject() = 扣动扳机

          Runtime.class
          ┌──────┐
          │ 子弹  │
          └──┬───┘
             │  getMethod → invoke → exec
  ┌──────────┼──────────────────────────┐
  │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │  ← 枪管 (ChainedTransformer)
  │     一节火药       二节火药       三节火药   │
  └──────────────────────────────┬─────┘
                                 │
                            ┌────┴────┐
                            │  扳机    │  ← setValue()
                            └────┬────┘     (TransformedMap)
                                 │
                            ┌────┴────┐
                            │ 扣动扳机 │  ← readObject()
                            └─────────┘     (AnnotationInvocationHandler)
```

每个零件单独拆开，都是再正常不过的设计。组合在一起，就是一把上了膛的枪。

一句话总结这一章：

> **`setValue()` 会成为扳机，不是因为它危险，而是因为 `TransformedMap` 必须保证连这条写入路径也会触发转换；攻击链利用的，正是这种"设计上必须成立"的一致性。**
每个零件单独拆开，都是再正常不过的设计。组合在一起，就是一把上了膛的枪。
答案不在 CC 的 functor 包，在 CC 的其他 240 个类。

### CC 有 273 个类，functor 只有 40 多个

```
commons-collections-3.2.1.jar (273 个类)
│
├── 被大量使用的 (220+ 个类)
│   ├── CollectionUtils   — isEmpty、isNotEmpty，到处都在用
│   ├── MapUtils          — 同上
│   ├── LRUMap            — LRU 缓存，Hibernate、Servlet 容器在用
│   ├── MultiMap          — 一个 key 对应多个 value
│   ├── Bag               — 计数集合（Multiset）
│   ├── BidiMap           — 双向 Map
│   ├── BeanMap           — JavaBean 反射成 Map
│   └── 各种装饰器         — Unmodifiable、Synchronized、FixedSize...
│
└── 几乎没人用的 (40+ 个 functor 类)
    ├── InvokerTransformer    ← CC1 的核心
    ├── ChainedTransformer    ← CC1 的核心
    ├── ConstantTransformer   ← CC1 的核心
    └── ...
```

### 依赖链：你的项目不需要 CC，但你的框架需要

```
你的项目
  └── spring-webmvc
        └── ...
              └── commons-collections-3.2.1.jar  ← 躺在这里
```

你从来没有 `import org.apache.commons.collections.functors.*`，但编译出来的 WAR 包 `WEB-INF/lib` 里，`commons-collections-3.2.1.jar` 安安静静地躺着。

两个条件同时成立，CC1 链就能打穿：① classpath 上有 CC 的 jar；② 应用暴露了反序列化入口。

那框架到底在用 CC 的什么？以下是 CC 3.x 中真正被广泛使用的类：

| 类 | 用途 |
|---|------|
| `CollectionUtils` | 集合判空、过滤、转换等静态工具方法 |
| `MapUtils` | Map 判空、安全取值 |
| `ListUtils` | List 差集、交集、分区 |
| `LRUMap` | LRU 缓存，Hibernate、Servlet 容器大量使用 |
| `MultiHashMap` | 一个 key 对应多个 value |
| `Bag` / `HashBag` | 计数集合（Multiset） |
| `BidiMap` | 双向 Map，key↔value 互查 |
| `BeanMap` | 反射 JavaBean 为 Map |
| `FastHashMap` | 装饰器模式的快速 Map |

这些才是 CC 被广泛依赖的原因。40 个 functor 类无人问津，但跟着一起被塞进了无数 classpath——门票是这些工具类买的。

### CC 4.x 的修复：去掉 Serializable

Apache 后来意识到问题，在 CC 4.x 中把 `InvokerTransformer` 的 `Serializable` 接口去掉了：

**CC 3.2.1：**

```java
public class InvokerTransformer implements Transformer, Serializable {
    private static final long serialVersionUID = -8653385846894047688L;
    private final String iMethodName;
    private final Class[] iParamTypes;
    private final Object[] iArgs;

    public Object transform(Object input) {
        Class cls = input.getClass();
        Method method = cls.getMethod(iMethodName, iParamTypes);
        return method.invoke(input, iArgs);
    }
}
```

**CC 4.4：**

```java
public class InvokerTransformer<I, O> implements Transformer<I, O> {
    private final String iMethodName;
    private final Class<?>[] iParamTypes;
    private final Object[] iArgs;

    public O transform(Object input) {
        // 内部逻辑完全一样
    }
}
```

`transform()` 的逻辑完全没变。修复没动功能，只动了接触面：把 `Serializable` 去了。
不能被序列化，就无法进入反序列化攻击链。另外 CC 4.x 改了包名和 groupId，迁移成本太高，
大多数项目至今仍停留在 CC 3.x。

## 附录：环境信息

| 组件 | 版本 |
|------|------|
| JDK | 1.8.0_60 |
| Commons Collections | 3.2.1 |
| 关键依赖位置 | `org.apache.commons.collections.functors` |
