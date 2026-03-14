- - # WebKitHardening

    Coruna 漏洞工具的第一步是运行 Stage1 浏览器漏洞。  
    只要 Stage1 跑不起来，后面的利用链也就没法继续。

    这个插件就是通过阻止 Stage1 运行来避免漏洞被利用。

    Coruna 项目里有三个 Stage1，大致对应的防护方式是：

    Stage1_15.2_15.5_jacurutu.js → 禁用 JIT  
    Stage1_16.2_16.5.1_terrorbird.js → 禁用 WebAssembly  
    Stage1_16.6_17.2.1_cassowary.js → 阻止 JIT 可执行内存  

    插件设置里的三个选项就是这三个：

    禁用 JIT  
    禁用 WebAssembly  
    阻止 JIT 可执行内存  

    打开对应选项就可以让对应的 Stage1 跑不起来。

    目前只测试过 terrorbird，另外两个 Stage1 理论上也能挡住，但没有实际测试。

    因为禁用了 WebAssembly 和 JIT，有些网页可能会打不开或者性能变慢。

    测试设备：  
    iPhone 14 Pro  
    iOS 16.5  
    Dopamine 越狱 (rootless)

    代码是 AI 写的，没测试的两个 Stage 的理论也是 AI 提出来的。

    Coruna 项目：  
    https://github.com/khanhduytran0/coruna

    terrorbird 示例 exploit：  
    https://github.com/khanhduytran0/coruna/blob/main/Stage1_16.2_16.5.1_terrorbird.js