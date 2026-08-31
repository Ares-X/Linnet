--[[
	无感造词（auto_phrase）

	来源：amzxyz/rime-wanxiang lua/wanxiang/auto_phrase.lua（CC BY 4.0）
	适配：Linnet 中文方案（linnet_zh / linnet_zh_*）

	行为：当用户逐段选字组成多字词并上屏时，把整词写入
	用户词典（与主翻译器同一本 linnet_zh.userdb），下次输入相同编码时
	整词直接作为候选出现，不再需要重新逐字选字。

	与万象实现的差异：
	- 移除英文造词分支（Linnet 的英文由独立方案/翻译器负责）。
	- 编码直接来自每段选中 Phrase，由同一本 Memory 解码；不从显示注释
	  反推读音，也不缓存文本。重复多音字与其他会话不会覆盖已选读音。
	- 配置移到 auto_phrase 小节：auto_phrase/enable、
	  auto_phrase/max_word_length。

	安全限制（与万象一致）：
	- 仅纯汉字文本（CJK 基本区 + 扩展 A~G）。
	- 仅"多段逐字选字"上屏（编码段数 == 字数）。
	- 仅接受与主翻译器相同词典的 Phrase；已有词由原生用户词典合并学习。
	- 每个编码片段必须是拼音字母（含声调符号；linnet_zh 词库使用带声调
	  的拼音编码，如 huáng，用户词典键与词库格式一致，声调原样保留）。
	- 超过 auto_phrase/max_word_length 字的不造（默认 7，与万象一致）。

	清除：用户词典中的词可用 Delete 键删除（候选标记为用户词时）；
	上屏后立即按 BackSpace 可撤销本次学习（librime 事务回滚）。
--]]

local AP = {}

-- 判断文本是否只含汉字（CJK 基本区 + 扩展 A~G）
local function is_chinese_only(text)
    if not text or text == "" then
        return false
    end
    if text:match("[%w%p]") then
        return false
    end
    for _, cp in utf8.codes(text) do
        if not (
            (cp >= 0x4E00 and cp <= 0x9FFF) or -- CJK Unified Ideographs
            (cp >= 0x3400 and cp <= 0x4DBF) or -- CJK Ext-A
            (cp >= 0x20000 and cp <= 0x2EBEF)  -- CJK Ext-B~G
        ) then
            return false
        end
    end
    return true
end

-- 拼音字母（含声调符号）。linnet_zh 词库的编码带声调（如 huáng），
-- 用户词典键与词库格式一致，因此写入时保留声调原样。
local pinyin_letters = "a-zA-Zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüńňǹḿ"
local pinyin_part = "^[" .. pinyin_letters .. "]+$"

function AP.init(env)
    local config = env.engine.schema.config

    -- The bundled schema and Settings projection own this value. Missing or
    -- malformed configuration fails closed instead of silently enabling a
    -- second product default inside Lua.
    env.enable = config:get_bool("auto_phrase/enable") == true

    local max_word_length = config:get_int("auto_phrase/max_word_length")
    if not max_word_length or max_word_length <= 0 then
        max_word_length = 7
    end
    env.max_word_length = max_word_length

    -- 写入主翻译器的用户词典（linnet_zh.userdb）。
    -- 注意：librime-lua 的 Memory 未设置 memorize 回调时，其原生 OnCommit
    -- 学习为 no-op（LuaMemory::Memorize 直接返回 false），不会造成重复学习；
    -- 这里只显式调用 update_userdict 写入多段选择；完整单候选仍只由
    -- 主翻译器学习，不再根据浏览过的文本猜测词库是否已有整词。
    env.memory = Memory(env.engine, env.engine.schema, "translator")

    local ctx = env.engine.context
    env._commit_conn = ctx.commit_notifier:connect(function(c)
        AP.commit_handler(c, env)
    end)
end

function AP.fini(env)
    if env._commit_conn then
        env._commit_conn:disconnect()
        env._commit_conn = nil
    end
    if env.memory then
        env.memory:disconnect()
        env.memory = nil
    end
end

-- 过滤器仅注册学习回调，不读写候选；释义/纠错等显示过滤器不拥有编码。
function AP.func(input)
    for cand in input:iter() do
        yield(cand)
    end
end

-- 上屏处理：检测"逐字选字"组成的整词，写入用户词典
function AP.commit_handler(ctx, env)
    if not env.enable or not env.memory or not ctx or not ctx.composition then
        return
    end

    local segments       = ctx.composition:toSegmentation():get_segments()
    local segments_count = #segments
    local commit_text    = ctx:get_commit_text() or ""

    if utf8.len(commit_text) <= 1 then
        return
    end
    if not is_chinese_only(commit_text) then
        return
    end
    -- 长度上限（与万象 max_word_length: 7 一致）
    if utf8.len(commit_text) > env.max_word_length then
        return
    end

    local code_table = {}
    local selected_count = 0
    for i = 1, segments_count do
        local seg  = segments[i]
        local cand = seg:get_selected_candidate()

        -- 无候选：最后一个段允许跳过（如标点/符号段）
        if not cand then
            if i ~= segments_count then
                return
            end
        else
            -- 与 librime Memory 的学习路径一致，解开 Shadow/Uniquified
            -- 后读取实际选中的 Phrase。不同词典的数值编码不能混用。
            local phrase = cand:get_genuine():to_phrase()
            if not phrase or phrase.lang_name ~= env.memory.lang_name then
                return
            end
            local code = env.memory:decode(phrase.code)
            if #code ~= utf8.len(cand.text) then
                return
            end
            selected_count = selected_count + 1
            for _, part in ipairs(code) do
                if not part:match(pinyin_part) then
                    return
                end
                table.insert(code_table, part)
            end
        end
    end

    -- 尾部空段不算一次选择：完整单候选仍由主翻译器学习。
    -- 编码片段数必须与字数一致，才是按字逐段组成的整词。
    if selected_count <= 1 or #code_table ~= utf8.len(commit_text) then
        return
    end

    local dictEntry = DictEntry()
    dictEntry.text        = commit_text
    dictEntry.weight      = 1
    dictEntry.custom_code = table.concat(code_table, " ") .. " "
    env.memory:update_userdict(dictEntry, 1, "")
end

return AP
