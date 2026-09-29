
test "maker: routers' vendor prefixes and nested slugs" {
    try expectMaker("anthropic", "openrouter", "anthropic/claude-sonnet-5");
    try expectMaker("openai", "groq", "openai/gpt-oss-120b");
    try expectMaker("alibaba", "vercel", "alibaba/qwen3-coder");
    try expectMaker("moonshot", "fireworks", "accounts/fireworks/models/kimi-k3");
    try expectMaker("google", "cerebras", "gemma-4-27b");
}
