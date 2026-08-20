--[[
	无感造词（auto_phrase）

	来源：amzxyz/rime-wanxiang lua/wanxiang/auto_phrase.lua（CC BY 4.0）
	适配：Linnet 中文方案（linnet_zh / linnet_zh_*）

	行为：当用户逐字选字组成一个词库中没有的多字词并上屏时，把整词写入
	用户词典（与主翻译器同一本 linnet_zh.userdb），下次输入相同编码时
	整词直接作为候选出现，不再需要重新逐字选字。

	与万象实现的差异：
	- 移除英文造词分支（Linnet 的英文由独立方案/翻译器负责）。
	- 注释里的编码按 Linnet 的 comment_format（［］包装的全拼）提取，
	  与 corrector.lua 使用相同的匹配规则，因此本过滤器必须放在
	  corrector 之前（corrector 会清空非纠错候选的注释）。
	- 配置移到 auto_phrase 小节：auto_phrase/enable、
	  auto_phrase/max_word_length。

	安全限制（与万象一致）：
	- 仅纯汉字文本（CJK 基本区 + 扩展 A~G）。
	- 仅"多段逐字选字"上屏（编码段数 == 字数）。
	- 本次会话中已经作为候选项出现过的文本不重复造（词库已有的词不造）。
	- 每个编码片段必须是拼音字母（含声调符号；linnet_zh 词库使用带声调
	  的拼音编码，如 huáng，用户词典键与词库格式一致，声调原样保留）。
	- 超过 auto_phrase/max_word_length 字的不造（默认 7，与万象一致）。

	清除：用户词典中的词可用 Delete 键删除（候选标记为用户词时）；
	上屏后立即按 BackSpace 可撤销本次学习（librime 事务回滚）。
--]]

local AP = {}

-- 注释缓存：text -> 全拼编码（已去掉 ［］ 包装）
local comment_cache = {}

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

-- 从候选注释中提取全拼编码。
-- Linnet 的 translator/comment_format 把注释包装成 ［全拼］，
-- corrector.lua 用同一匹配规则（^［(.-)］$）判断。
-- 其他来源的注释（英文词、反查等）不匹配时返回 nil，表示不参与造词。
local function extract_code(comment)
    if not comment or comment == "" then
        return nil
    end
    local inner = comment:match("^［(.-)］$")
    if not inner or inner == "" then
        return nil
    end
    return inner
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
    -- 这里只显式调用 update_userdict 写入"逐字选字"场景下新组成的词。
    env.memory = Memory(env.engine, env.engine.schema, "translator")

    local ctx = env.engine.context
    env._commit_conn = ctx.commit_notifier:connect(function(c)
        AP.commit_handler(c, env)
    end)
    -- 删除事件只用于清理注释缓存
    env._delete_conn = ctx.delete_notifier:connect(function()
        comment_cache = {}
    end)
end

function AP.fini(env)
    if env._commit_conn then
        env._commit_conn:disconnect()
        env._commit_conn = nil
    end
    if env._delete_conn then
        env._delete_conn:disconnect()
        env._delete_conn = nil
    end
    if env.memory then
        env.memory:disconnect()
        env.memory = nil
    end
end

-- 过滤器：缓存候选文本对应的全拼编码，候选原样通过
function AP.func(input, env)
    if env.enable then
        for cand in input:iter() do
            local genuine = cand:get_genuine()
            local code = extract_code(genuine.comment)
            if code then
                comment_cache[cand.text] = code
            end
            yield(cand)
        end
    else
        for cand in input:iter() do
            yield(cand)
        end
    end
end

-- 上屏处理：检测"逐字选字"组成的整词，写入用户词典
function AP.commit_handler(ctx, env)
    if not ctx or not ctx.composition then
        comment_cache = {}
        return
    end
    if not env.enable then
        return
    end

    local segments       = ctx.composition:toSegmentation():get_segments()
    local segments_count = #segments
    local commit_text    = ctx:get_commit_text() or ""

    -- 基础检查：至少两个段、至少两个汉字
    if segments_count <= 1 or utf8.len(commit_text) <= 1 then
        comment_cache = {}
        return
    end
    -- 只造纯汉字词；本次会话中已作为候选出现过的文本（即词库已有的词）不重复造
    if not is_chinese_only(commit_text) or comment_cache[commit_text] then
        comment_cache = {}
        return
    end
    -- 长度上限（与万象 max_word_length: 7 一致）
    if utf8.len(commit_text) > env.max_word_length then
        comment_cache = {}
        return
    end

    local config = env.engine.schema.config
    local delimiter = config:get_string("speller/delimiter") or " '"
    local escaped_delimiter = utf8.char(utf8.codepoint(delimiter)):gsub("(%W)", "%%%1")

    local code_table = {}
    for i = 1, segments_count do
        local seg  = segments[i]
        local cand = seg:get_selected_candidate()

        -- 无候选：最后一个段允许跳过（如标点/符号段）
        if not cand then
            if i ~= segments_count then
                comment_cache = {}
                return
            end
        else
            local code = comment_cache[cand.text]
            -- 有候选但无（已匹配的）编码：最后一个段允许跳过
            if not code or code == "" then
                if i ~= segments_count then
                    comment_cache = {}
                    return
                end
            else
                -- 编码按分隔符拆成片段；片段必须是拼音字母（含声调），
                -- 否则视为无效（防御性检查，防止脏数据写入用户词典）
                local valid = true
                for part in code:gmatch("[^" .. escaped_delimiter .. "]+") do
                    if part:match(pinyin_part) then
                        table.insert(code_table, part)
                    else
                        valid = false
                        break
                    end
                end
                if not valid then
                    comment_cache = {}
                    return
                end
            end
        end
    end

    -- 编码片段数必须与字数一致：保证整词是按字逐段选出来的
    if #code_table == 0 or #code_table ~= utf8.len(commit_text) then
        comment_cache = {}
        return
    end

    if not env.memory then
        comment_cache = {}
        return
    end

    local dictEntry = DictEntry()
    dictEntry.text        = commit_text
    dictEntry.weight      = 1
    dictEntry.custom_code = table.concat(code_table, " ") .. " "
    env.memory:update_userdict(dictEntry, 1, "")

    comment_cache = {}
end

return AP
