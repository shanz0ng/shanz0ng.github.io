---
pubDatetime: 2026-06-26
title: “从三块积木到一把枪——CC 组件里的函数式思路”
postSlug: cc-functors-functional-programming
featured: false
draft: false
tags:
  - Java
  - 代码审计
  - 反序列化
  - Commons Collections
  - 函数式编程
description: “拆解 Commons Collections functor 体系的三大核心积木，看它们如何从对象组装变成反序列化攻击链。”
---

# 从三块积木到一把枪——CC 组件里的函数式思路

前半部分，先拆开看 Commons Collections functor 体系里的三块核心积木：ConstantTransformer、InvokerTransformer 和 ChainedTransformer。看看它们怎样把”先把处理步骤单独抽出来，再按顺序接起来”这类思路翻译成 Java 对象组合。

后半部分，再看这三块积木如何被装进 TransformedMap，又如何在 AnnotationInvocationHandler.readObject() 的参与下接入反序列化流程，最终从“可表达的一条链”变成“一把会响的枪”。

---
## 一、背景：2004 年，CC 开发者想在 Java 里引入这类组织思路
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

其中有三块很关键的积木，后面也正好成了 CC1 链里的核心部件：

| 表达 | CC 实现类 |
|----------|-----------|
| `f(x) = c`（常量函数） | `ConstantTransformer` |
| 把一次调用包装成一步 | `InvokerTransformer` |
| `f(x) = f₃(f₂(f₁(x)))`（函数复合） | `ChainedTransformer` |

十年后 Java 8 发布，`java.util.function` 包也提供了非常接近的一套概念体系，至少说明 CC 当年试图在 Java 里模拟这类能力，并不是一个偏门想法。

### 1.1 把 CC 放到 Java 8 之后再看

如果借今天的眼光回头看，会发现 CC 这套 functor 接口和 Java 8 的标准函数接口，在思路上非常接近：它们都在描述“把一段处理逻辑单独拿出来，再交给别的代码去执行”。

| CC functor | Java 8 中最接近的接口 | 含义 |
|------------|------------------------|------|
| `Transformer` | `Function<T, R>` | 给一个输入，返回一个输出 |
| `Predicate` | `Predicate<T>` | 给一个输入，判断真假 |
| `Closure` | `Consumer<T>` | 接收一个输入，执行动作，不返回结果 |
| `Factory` | `Supplier<T>` | 不要输入，直接产出一个值 |

如果再往本文这三块积木上对照，`ConstantTransformer` 可以近似看成 `x -> c`，`InvokerTransformer` 可以近似看成“对输入对象做一步既定调用”，`ChainedTransformer` 则对应多个 `Function` 的串联。

如果只看“多个步骤接起来”这件事，两边也很像。CC 里用的是 `ChainedTransformer`，Java 8 里则可以直接用 `Function` 的 `andThen()` / `compose()`：

```java
Function<String, String> f =
    ((Function<String, String>) String::trim)
        .andThen(String::toUpperCase);

System.out.println(f.apply("  hello  "));  // HELLO
```

这段代码表达的是：

```text
f(x) = f₂(f₁(x))
```

这就是把多个处理步骤接起来。

从这个角度看，CC 和 Java 8 的思路是共通的。

## 二、用函数式的视角看这三块积木

为了方便理解这三块积木，可以抓住三个词：起点、步骤、组合。

这里真正想借的，是一种看问题的方式：**先把步骤拆开，再把它们接起来。**

这种“拆开再组合”的思路，比 Java 老得多。再往上追，它的数学根基可以追溯到 1930 年代阿隆佐·丘奇提出的 λ 演算。

```
f(x) = x² + 1    ← 给定输入 x，按规则得到结果
```

CC 的 `Transformer`，可以近似理解成这里的 `f(x)`。
下面看一条大家都非常熟悉的命令：

```bash
echo baidu.com | ./SubFinder/subfinder -silent | ./KsubDomain/ksubdomain -silent | ./HTTProbe/httprobe | ./HTTPX/httpx -title/-ip
```

它的作用是：从 baidu.com 出发，发现子域名，筛选存活的，加上 https://，提取页面标题。每一步是一个独立的工具，管道符把这些工具串成了流水线，上一个工具的输出是下一个工具的输入。

这条命令里，正好能把这种思路拆成三个动作，逐个看——

### 2.1 固定一个结果 `f(x) = c`

最简单的函数，是不管你给它什么输入，输出都一样：

```text
f(x) = c
```

`ConstantTransformer` 很像流水线最开头那个“先给一个起点”的步骤：它不处理上游输入，只负责固定给出一个值。

这里的 `c` 是一个固定值。无论输入是 `x=1`、`x="hello"`，还是 `x=null`，结果都不会变。

```java
new ConstantTransformer("baidu.com").transform(null);  // → "baidu.com"
```
### 2.2 把一次调用包装成一步

`InvokerTransformer` 干的事情，可以直接理解成：先把一次方法调用需要的信息记下来，等真正拿到输入对象时，再在这个对象上把这次调用执行掉。

比如，它会先记住：

- 调哪个方法
- 参数类型是什么
- 参数值是什么

等输入对象来了，再按这套规则去调。

这样一来，“调一个方法”就不再只是临时写在代码里的一行语句，而是被包装成了流水线里可以单独拿出来的一步。

也正因为每一步都能这样单独包装，后面的 `ChainedTransformer` 才能继续把这些步骤串起来。

### 2.3 多个步骤可以串起来 `F(x) = f₃(f₂(f₁(x)))`

有了前面这些步骤，下一步就是把它们接起来。

```text
F(x) = f₃(f₂(f₁(x)))
```

意思是：

- 先执行 `f₁`
- 它的输出交给 `f₂`
- `f₂` 的输出再交给 `f₃`

这样一层层接下去，就形成了一条流水线。

如果借 Linux 管道来打比方，整条命令：

```text
echo baidu.com | subfinder | ksubdomain | httprobe | httpx
```

从处理结构上看，可以近似看成函数复合：

```text
f(baidu.com) = httpx(httprobe(ksubdomain(subfinder(baidu.com))))
```

CC 里的 `ChainedTransformer` 干的就是把这些步骤接起来。

### 2.4 CC 用 40+ 个类实现了这套体系
上面这三类基础积木，CC 的 functors 包里 40+ 个类都是它们的变体和组合。第二章先讲思路，下面直接看它们在 Java 里是怎么拼起来的。

---

## 三、把管道符翻译成 Java

第二章讲的是思路，这一章就不再重复解释“流水线”本身了，直接把前面的类比翻译成 Java 里的 F1、F2、F3。

```bash
echo baidu.com | ./SubFinder/subfinder -silent | ./KsubDomain/ksubdomain -silent | ./HTTProbe/httprobe | ./HTTPX/httpx -title/-ip
```

如果只看处理结构，可以先把每条命令近似看成一步处理：

```
echo baidu.com  → 类比成一步 F1        = 常量函数，提供起始值
subfinder      → 类比成一步 F2         = 抽出来的一步
ksubdomain     → 类比成一步 F2         = 抽出来的一步
httprobe       → 类比成一步 F2         = 抽出来的一步
httpx          → 类比成一步 F2         = 抽出来的一步
整条管道        → F3([F1,F2,F2,F2,F2]) = 函数组合
```
三个积木的定义：

```java
// F1：f(x) = c — 不管输入是什么，永远返回固定值
static Transformer F1(Object constant) {
    return new ConstantTransformer(constant);
}

// F2：近似看成 f(x) = x.m(a) — 把一次方法调用包装成流水线里的一步
static Transformer F2(String method, Class[] types, Object[] args) {
    return new InvokerTransformer(method, types, args);
}

// F3：f(x) = f₃(f₂(f₁(x))) — 把多个函数串成管道
static Transformer F3(Transformer[] transformers) {
    return new ChainedTransformer(transformers);
}
```

如果不用这套积木，2004 年的 Java 代码通常会写成这样：

```java
// 2004 年，没有泛型，没有方法链，每步一个中间变量
String domain = "baidu.com";
List subs = SubFinder.getSubdomains(domain);
List alive = KsubDomain.filterAlive(subs);
List urls = HttpProbe.addHttps(alive);
List results = HttpX.extractTitles(urls);
```

在 2004 年的 Java 里，这套写法还没有现成、统一的表达。Commons Collections 把它显式包装成了三块积木。

下面开始看，参数一换，它为什么会从正常处理流程变成利用链。

## 四、设计者没预料到的用法

F1、F2、F3 是通用积木。设计者没有限制你能传什么参数——这种抽象积木本来就不关心你拿它去处理什么。

但攻击者发现：**同一套积木，把参数换掉，就能从正常处理流程变成危险调用链。**

```
设计者往管道里装的：            攻击者往管道里装的：
─────────────────────          ─────────────────────
F1("baidu.com")                F1(Runtime.class)
F2("subfinder")                F2("getMethod", [String,Class[]], ["getRuntime",null])
F2("ksubdomain")               F2("invoke",    [Object,Object[]], [null,null])
F2("httprobe")                 F2("exec",      [String],          ["calc"])
F2("httpx")

F3 这层没变，变的是前面每一步装进去的参数
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
API 没变，设计意图没变。变的是传进去的参数。设计者造了积木，攻击者用这些积木搭了一把枪。

不过，第四章这把枪还只是我们手动扣响的。要进入反序列化利用，还差一个能自动把整条链带起来的入口。

---

## 五、设计深处的那根引线

接下来要看的，就是这个自动触发点。反序列化攻击不会靠攻击者亲手去调 `transform()`——它总得借助反序列化过程中某个**自动执行**的入口。

这根引线，一头连着 `TransformedMap`，另一头连着 `AnnotationInvocationHandler.readObject()`。

---

### 5.1 `TransformedMap` 想解决什么问题？

先看它原本的设计目标。

`TransformedMap.decorate(map, null, valueTransformer)` 是在原始 `map` 外面包一层，让它变成一个“写 value 前先经过 `valueTransformer` 处理”的 `Map`。

它想解决的问题很朴素：

> 我已经有一个普通 `Map`，但我希望以后无论谁往里面写值，都自动先做一遍转换。

比如：

- 字符串先 `trim()`
- 统一转小写
- 做类型适配
- 做格式清洗

`ConstantTransformer` 很像流水线最开头那个“先给一个起点”的步骤；而 `TransformedMap` 想做的，则是把“写值之前先处理一下”这件事稳定接进 `Map` 的写入流程里。

**`TransformedMap` 的关键，不是“它能调用 `transform()`”，而是“它试图保证所有写入都先经过 `transform()`”。**

### 5.2 难点：写入口不止一个

如果只从直觉出发，很多人会以为“往 Map 里写值”只有一种方式：

```java
map.put(key, value);
```

但实际上还有另一条路：

```java
map.entrySet().iterator().next().setValue(value);
```

调用方完全可以先拿到一个 `Map.Entry`，再直接改它的值。

这就引出了 `TransformedMap` 设计里最关键的一点：

> **如果它只拦截 `put()`，却放过了 `Map.Entry.setValue()`，那它就没法保证“所有写入都经过转换”。**

所以，对一个“写入自动转换”的 `Map` 来说，`setValue()` 不是边角细节，而是很难绕开的写入口。

### 5.3 它是怎么把 `setValue()` 接进来的？

Commons Collections 的做法是：

`entrySet()` 返回的不是底层原始 `Entry`，而是包装过的 `Entry`。

核心逻辑可以浓缩成这样：

```java
public Object setValue(Object value) {
    value = parent.checkSetValue(value);
    return entry.setValue(value);
}
```

意思很简单：

1. 外界调用 `setValue()`
2. 不直接写回底层 Map
3. 先经过 `checkSetValue()`
4. 再写入

所以在这里，`setValue()` 已经不再只是普通写值，而是被接进了“写前先处理”的流程里。

### 5.4 为什么它最后会通到 `transform()`？

因为在 `TransformedMap` 里，`checkSetValue()` 的实现就是：

```java
protected Object checkSetValue(Object value) {
    return valueTransformer.transform(value);
}
```

于是链路自然接通：

```text
entry.setValue(x)
   ↓
checkSetValue(x)
   ↓
valueTransformer.transform(x)
```

顺着这条链往下看，前面那句“所有写入都先经过 `transform()`”，在这里就落到了代码上。

也正因为这样，后面只要有人替攻击者调用了 `entry.setValue()`，这条链就会被点燃。

### 5.5 谁点燃了这根引线？

前面 `TransformedMap` 这一侧已经讲清楚了：只要有人调用 `entry.setValue(x)`，执行流就会一路进入 `checkSetValue(x)`，再进入 `valueTransformer.transform(x)`。

`TransformedMap` 已经把引线埋好了。  
接下来只剩一个问题：

> **反序列化过程中，到底是谁替攻击者调用了这一下 `entry.setValue()`？**

在 CC1 里，答案是：`AnnotationInvocationHandler.readObject()`。

### 5.6 `AnnotationInvocationHandler` 在这里扮演什么角色？

`AnnotationInvocationHandler` 在这里做的事情很具体：它内部维护着一张表，记录“注解成员名 → 成员值”的对应关系。

拿代码审计里经常见到的 Spring 控制器写法来举例：

```java
@RestController
@RequestMapping(value = "/user", method = RequestMethod.GET)
public class UserController {

    @GetMapping("/list")
    public String list() {
        return "ok";
    }
}
```

如果只盯住类上的这个 `@RequestMapping`，可以把它粗略理解成一张这样的表：

```text
value  -> "/user"
method -> GET
```

这里：

- `value`、`method` 是**注解成员名**
- `"/user"`、`GET` 是**这些成员当前对应的值**

对 JDK 来说，注解在运行时最终会落成一组“名字 -> 值”的映射关系，而 `AnnotationInvocationHandler` 管的正是这张表。

`readObject()` 的任务，就是在反序列化完成后重新检查这张表里的内容是否还对得上当前注解定义：成员名要存在，成员值类型也要匹配。因为 `defaultReadObject()` 只负责把字段从字节流里恢复回来，并不保证恢复之后仍然构成一个**合法的注解对象**。

所以 `readObject()` 在把 `type` 和 `memberValues` 读回来之后，还要再做一次“体检”。如果发现某一项不匹配，它不会重建整个 Map，也不会立刻抛异常，而是会在遍历当前条目时直接调用：

```java
entry.setValue(...)
```

把这一项原地换成 `AnnotationTypeMismatchExceptionProxy`，等以后有人访问这个成员时，再按规范抛异常。

也正因为 `readObject()` 会在这里调用 `entry.setValue(...)`，前面埋在 `TransformedMap` 里的那根引线，才终于有了被点燃的机会。

### 5.7 这为什么会接上 CC1？

如果这张表只是普通 `Map`，这就是一次普通的修值动作。  
但在 CC1 里，攻击者把这张表换成了 `TransformedMap`。

这里还有一个很容易忽略的点：CC1 并不是把一份“完全正常”的注解成员表塞进 `AnnotationInvocationHandler`，再等它自然触发。相反，攻击者需要故意构造一份“成员名正确，但成员值类型错误”的 `memberValues`。

以 `Target.class` 为例，`value()` 成员期望的是 `ElementType[]`，而 payload 却故意塞入一个 `String`。这样一来，`readObject()` 在类型检查时就会发现不匹配，从而进入 `memberValue.setValue(...)`。而这次本来只是为了“修正错误值”的 `setValue()`，正好被 `TransformedMap` 接进了 transformer 链。

于是这次 `setValue()` 就不再只是改值，而会继续进入：

```text
readObject()
 -> entry.setValue(...)
 -> checkSetValue(...)
 -> transform(...)
 -> ChainedTransformer
```

链路也就在这里接通了。

CC1 利用的不是 `AnnotationInvocationHandler` 自己去执行什么危险操作，而是它在反序列化时那次“修值”动作，恰好撞上了攻击者提前埋好的 `TransformedMap`。

### 5.8 五个零件，一把枪

```text
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
  ┌──────────┼───────────────────────────────┐
  │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │  ← 枪管 (ChainedTransformer)
  │     一节火药       二节火药       三节火药   │
  └──────────────────────────────┬───────────┘
                                 │
                            ┌────┴────┐
                            │  扳机    │  ← setValue()
                            └────┬────┘     (TransformedMap)
                                 │
                            ┌────┴────┐
                            │ 扣动扳机 │  ← readObject()
                            └─────────┘     (AnnotationInvocationHandler)
```

每个零件单独拆开看，都是很正常的设计。  
组合在一起，就是一把上了膛的枪。

一句话总结这一章：

> `setValue()` 会成为引线，不是因为它天生危险，而是因为一边要保证“所有写入都经过转换”，另一边要在反序列化时“原地修正当前条目”；攻击链正是借用了这两个正常设计之间的接缝。

### 5.9 再看一眼 LazyMap 版：get() 是怎么把链子带起来的？

LazyMap 版的关键就在 `get()`。

#### 5.9.1 `LazyMap` 想解决什么问题？

普通 `Map.get()` 的语义很简单：有这个 key，就返回对应的 value；没有，就返回 `null`。

而 `LazyMap` 把 `get()` 改成了另一种语义：有这个 key，就正常返回；没有，就先现场生成一个 value，放回 `Map`，再把它返回。

如果借缓存来打比方，这个设计就很好理解了。

比如一张 `Map` 用来缓存网页内容，key 是 URL，value 是页面 HTML。普通 `Map` 在缓存未命中时，只会返回 `null`；而 `LazyMap` 可以把这一步改成：

- 先抓一次这个 URL 的页面
- 把抓到的 HTML 放回 `Map`
- 再把结果返回给调用方

如果用代码把这个想法写出来，大概像这样：

```java
Map<String, String> cache = new HashMap<>();

String getHtml(String url) {
    String html = cache.get(url);
    if (html == null) {
        html = HttpUtil.fetch(url);   // 第一次访问时现场抓取
        cache.put(url, html);         // 放回缓存
    }
    return html;
}
```

它把 `get(url)` 从“单纯取值”变成了：

> **取值 + 必要时现场生成 + 回填缓存**

这就是 `LazyMap` 里“懒”的意思：它不会一开始就把所有 value 都准备好，而是等某个 key 第一次被访问时，再去补出这个 value。所以这里的 “lazy”，更接近“延迟计算”或“按需生成”。

#### 5.9.2 这个设计为什么会被 CC1 利用？

问题就出在“现场生成”这一步交给谁来做。

在 `LazyMap` 里，如果某个 key 不存在，就会调用事先传进去的 `Transformer`，用这个 key 生成一个 value。

正常场景下，这本来只是一次很普通的自动补值逻辑；但在 CC1 的 `LazyMap` 版里，攻击者把这里的 `Transformer` 换成了 `ChainedTransformer`。

于是语义就变了：

- 原本是：key 不存在 → 补一个正常值
- 现在变成：key 不存在 → 触发一条 transformer 链

所以这里要盯住的，就是这一下：

```text
map.get(key)
```

只要调用最终落到 `LazyMap.get(...)`，并且这个 key 原本不存在，后面的 `transform()` 就会被带起来。

那 CC1 的 `LazyMap` 版，是谁替攻击者调用了这一下 `get()`？

答案不是 `readObject()` 直接去调了 `LazyMap.get()`，而是中间多了一层**动态代理**。

构造过程可以先压成这几步：

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


这里有两个 `AnnotationInvocationHandler`：

- **内层 `AnnotationInvocationHandler`**：包着 `LazyMap`，负责接住代理对象的方法调用
- **外层 `AnnotationInvocationHandler`**：包着 `proxyMap`，负责在反序列化时进入 `readObject()`

这里的 `proxyMap`，不是普通 `Map`，而是 JDK 动态代理生成出来的对象。

`new Class[]{Map.class}` 指定：这个代理对象要表现得像一个 `Map`；`innerHandler` 指定：以后谁调用这个 `Map` 的方法，都先交给 `innerHandler.invoke(...)`。

动态代理把这次 `proxyMap.entrySet()` 调用转发到了内层 `AnnotationInvocationHandler.invoke()`。

链路可以压成这样：

```text
outer AnnotationInvocationHandler.readObject()
 -> outer.memberValues.entrySet()          // 这里的 memberValues = proxyMap
 -> proxyMap.entrySet()
 -> inner AnnotationInvocationHandler.invoke()
 -> inner.memberValues.get("entrySet")     // 这里的 memberValues = LazyMap
 -> LazyMap.get("entrySet")
 -> ChainedTransformer.transform("entrySet")
```

进入 `invoke()` 之后，它会取出这次调用的方法名，也就是 `"entrySet"`，再拿这个名字去内部那张表里查值：

```text
memberValues.get("entrySet")
```

而这张表，恰好就是攻击者提前布置好的 `LazyMap`。因为 `LazyMap` 里原本并没有 `"entrySet"` 这个 key，所以 `get("entrySet")` 会走进懒加载分支，触发 `ChainedTransformer.transform(...)`。

## 番外：为什么 CC 组件的使用这么广泛？

一个值得思考的问题：**Java 8 已经在 `java.util.function` 包里提供了完整的函数式编程方案，`InvokerTransformer` 这些类几乎没人用了。可为什么 CC1 链依然还会在这么多服务器上出现利用条件？**

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

两个条件同时成立，CC1 链就能打穿：① classpath 上有 CC 的 jar；② 应用暴露了反序列化入口。

那框架到底在用 CC 的什么？以下是 CC 3.x 中被广泛使用的类：

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


























