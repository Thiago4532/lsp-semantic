local vim = vim
local api, lsp = vim.api, vim.lsp
local util, protocol = lsp.util, lsp.protocol
local bit = require'bit'

local function err_message(...)
    vim.notify(table.concat(vim.tbl_flatten{...}), vim.log.levels.ERROR)
    api.nvim_command("redraw")
end

local old_make_client_capabilities = protocol.make_client_capabilities;
local function make_client_capabilities()
    local tbl = old_make_client_capabilities()
    tbl['textDocument'].semanticTokens = {
        requests = {
            range = false,
            full = {
                delta = true
            }
        },
        multilineTokenSupport = false
    }
    return tbl
end

-- TODO: Support more than 23 modifiers
local function modifiers_to_bit_table(modifiers)
    local tbl, key = {}, 1
    for _,mod in ipairs(modifiers) do
        tbl[key] = mod
        key = key * 2
    end

    return tbl
end

local old_resolve_capabilities = protocol.resolve_capabilities
local function resolve_capabilities(server_capabilities)
    local tbl = old_resolve_capabilities(server_capabilities)

    local smp = server_capabilities.semanticTokensProvider
    if smp then
        tbl['semantic_tokens'] = {
            full = not not smp.full,
            full_delta = smp.full and smp.full.delta,
            range = not not smp.range,
        }
        tbl['semantic_tokens_types'] = smp.legend and smp.legend.tokenTypes or {}
        tbl['semantic_tokens_modifiers'] = modifiers_to_bit_table(smp.legend and smp.legend.tokenModifiers or {})
    else
        tbl['semantic_tokens'] = {
            full = false,
            full_delta = false,
            range = false,
        }
        tbl['semantic_tokens_types'] = {}
        tbl['semantic_tokens_modifiers'] = {}
    end

    return tbl
end

local function parse_modifiers(m, modifiers_tbl)
    local tbl = {}
    while m ~= 0 do
        local lsb = bit.band(m, -m)
        tbl[#tbl + 1] = modifiers_tbl[lsb]

        m = m - lsb  
    end

    return tbl
end

local function parse_data(data, types, modifiers_tbl)
    local line = 0
    local start = 0
    local length = 0
    local type = ""
    local modifiers = {}

    local tbl = {}
    for i=1,#data,5 do
        line = data[i] + line
        start = data[i+1] + (data[i] == 0 and start or 0)
        length = data[i+2]
        type = types[data[i+3] + 1]
        modifiers = parse_modifiers(data[i+4], modifiers_tbl)

        tbl[#tbl + 1] = {
            line = line,
            start = start,
            length = length,
            type = type,
            modifiers = modifiers,
        }
    end
    return tbl
end

local function parse_data_modified(data, types, modifiers_tbl, was_modified)
    local line = 0
    local start = 0
    local length = 0
    local type = ""

    local tbl = {}
    for i=1,#data,5 do
        line = data[i] + line
        start = data[i+1] + (data[i] == 0 and start or 0)
        length = data[i+2]
        type = types[data[i+3] + 1]

        if was_modified[line] then
            local modifiers = parse_modifiers(data[i+4], modifiers_tbl)
            tbl[#tbl + 1] = {
                line = line,
                start = start,
                length = length,
                type = type,
                modifiers = modifiers
            }
        end
    end
    return tbl
end

local previous_result_buffer = {}

local types_highlight = {
    ["namespace"] = "LspSemanticNamespace",
    ["type"] = "LspSemanticType",
    ["class"] = "LspSemanticClass",
    ["enum"] = "LspSemanticEnum",
    ["struct"] = "LspSemanticStruct",
    ["typeParameter"] = "LspSemanticTypeParameter",
    ["parameter"] = "LspSemanticParameter",
    ["variable"] = "LspSemanticVariable",
    ["property"] = "LspSemanticProperty",
    ["enumMember"] = "LspSemanticEnumMember",
    ["function"] = "LspSemanticFunction",
    ["method"] = "LspSemanticMethod",
    ["macro"] = "LspSemanticMacro",
    ["comment"] = "LspSemanticComment",
}

local function lsp_handler_full(_, result, ctx, _)
    -- local clock = vim.loop.hrtime()
    local client_id = ctx.client_id
    local client = vim.lsp.get_client_by_id(client_id)
    local bufnr = ctx.bufnr
    if not client or not result.data then 
        return
    end
    previous_result_buffer[bufnr] = result
    previous_result_buffer[bufnr].clientId = client_id

    local data = result.data
    local types = client.resolved_capabilities.semantic_tokens_types
    local modifiers = client.resolved_capabilities.semantic_tokens_modifiers

    local symbols = parse_data(data, types, modifiers)
    local ns = api.nvim_create_namespace("lsp-semantic-namespace")
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    for _,symbol in ipairs(symbols) do
        local line = symbol.line
        local col_start = symbol.start
        local col_end = col_start + symbol.length
        local hl = types_highlight[symbol.type] or "LspSemanticUnknown"

        api.nvim_buf_add_highlight(bufnr, ns, hl, line, col_start, col_end)
    end
    -- print("Full:", (vim.loop.hrtime() - clock) / 1e6)
end

local function lsp_handler_full_delta(_, result, ctx, _)
    if result.data then
        return lsp_handler_full(_, result, ctx, _);
    end
    local clock = vim.loop.hrtime()
    local client_id = ctx.client_id
    local client = vim.lsp.get_client_by_id(client_id)
    local bufnr = ctx.bufnr
    if not client or not result.edits then
        return
    end

    local edits = result.edits
    local prev = previous_result_buffer[bufnr].data

    table.sort(edits, function(a, b)
        return a.start < b.start
    end)

    local data = {}
    local was_modified = {}
    local line,cnt = 0,4
    local offset = 1

    for _,edit in ipairs(edits) do
        while offset <= edit.start do
            data[#data + 1] = prev[offset]
            cnt = cnt + 1
            if cnt == 5 then
                line = line + data[#data]
                cnt = 0
            end

            offset = offset + 1
        end
        if edit.deleteCount then
            offset = offset + edit.deleteCount
        end

        for _,v in ipairs(edit.data) do
            data[#data + 1] = v
            cnt = cnt + 1
            if cnt == 5 then
                line = line + data[#data]
                cnt = 0
            end

            was_modified[line] = true
        end
    end
    while offset <= #prev do
        data[#data + 1] = prev[offset]
        offset = offset + 1
    end

    previous_result_buffer[bufnr] = {
        data = data,
        resultId = result.resultId,
        clientId = client_id
    }

    local types = client.resolved_capabilities.semantic_tokens_types
    local modifiers = client.resolved_capabilities.semantic_tokens_modifiers
    local symbols = parse_data_modified(data, types, modifiers, was_modified)
    local ns = api.nvim_create_namespace("lsp-semantic-namespace")

    if #symbols == 0 then
        return
    end

    -- Clear highlight in range
    local line_start, line_end = symbols[1].line, symbols[1].line + 1
    for _,symbol in ipairs(symbols) do
        if symbol.line <= line_end then
            line_end = symbol.line + 1
        else
            api.nvim_buf_clear_namespace(bufnr, ns, line_start, line_end)
            line_start, line_end = symbol.line, symbol.line + 1
        end
    end
    api.nvim_buf_clear_namespace(bufnr, ns, line_start, line_end)

    -- Highlight symbols
    for _,symbol in ipairs(symbols) do
        local line = symbol.line
        local col_start = symbol.start
        local col_end = col_start + symbol.length
        local hl = types_highlight[symbol.type] or "LspSemanticUnknown"

        api.nvim_buf_add_highlight(bufnr, ns, hl, line, col_start, col_end)
    end
    print("Delta:", (vim.loop.hrtime() - clock) / 1e6)
end

local function dump_symbols()
    local bufnr = api.nvim_get_current_buf()

    local result = previous_result_buffer[bufnr]
    if not result then
        err_message("dump_symbols: semantic highlight is not enabled in the current buffer")
        return
    end

    local client_id = result.clientId 
    local client = vim.lsp.get_client_by_id(client_id)
    if not client then
        err_message(string.format("dump_symbols: client %d is not active anymore", client_id))
        return
    end

    local data = result.data
    local types = client.resolved_capabilities.semantic_tokens_types
    local modifiers = client.resolved_capabilities.semantic_tokens_modifiers
    return parse_data(data, types, modifiers)
end

local function dump_cursor()
    local symbols = dump_symbols()
    local cursor_row, cursor_col = unpack(api.nvim_win_get_cursor(0))
    if not symbols then
        return
    end

    local cursor_symbol = nil
    for _,symbol in ipairs(symbols) do
        local sym_line = symbol.line + 1
        local sym_start = symbol.start
        local sym_end = sym_start + symbol.length

        if sym_line == cursor_row then
            if sym_start <= cursor_col and cursor_col < sym_end then
                return symbol
            end
        end
    end

    -- No symbol was found
    return
end

function highlight_file()
    lsp.buf_request(0, "textDocument/semanticTokens/full", {
        textDocument = util.make_text_document_params()
    })
end

function highlight_file_delta()
    local bufnr = api.nvim_get_current_buf()

    if not previous_result_buffer[bufnr] then
        lsp.buf_request(0, "textDocument/semanticTokens/full", {
            textDocument = util.make_text_document_params()
        })
    else
        lsp.buf_request(0, "textDocument/semanticTokens/full/delta", {
            textDocument = util.make_text_document_params(),
            previousResultId = previous_result_buffer[bufnr].resultId
        })
    end
end

local function setup()
    protocol.make_client_capabilities = make_client_capabilities
    protocol.resolve_capabilities = resolve_capabilities

    lsp.handlers["textDocument/semanticTokens/full"] = lsp_handler_full
    lsp.handlers["textDocument/semanticTokens/full/delta"] = lsp_handler_full_delta
end

return {
    setup = setup,
    dump_symbols = dump_symbols,
    dump_cursor = dump_cursor
}
