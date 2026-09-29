
test "maker: the gateway serves other labs' models" {
    try expectMaker("anthropic", "codegraff", "claude-opus-5");
    try expectMaker("xiaomi", "codegraff", "mimo-v2.6-flash");
    try expectMaker("deepseek", "codegraff", "deepseek-v4-pro");
    try expectMaker("zai", "codegraff", "glm-5.3");
    try expectMaker("moonshot", "codegraff", "kimi-k3");
    try expectMaker("xai", "codegraff", "grok-4.7");
    try expectMaker("minimax", "codegraff", "minimax-m3");
    try expectMaker("openai", "codegraff", "gpt-5.6-sol");
    try expectMaker("meta", "codegraff", "muse-spark");
}
