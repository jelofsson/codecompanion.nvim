--[[
PLEASE NOTE: This adapter is not supported by CodeCompanion.nvim.
It is simply provided as an example for how you can connect a Claude-compatible endpoint
to CodeCompanion via an adapter. Send any questions or queries to the discussions.
--]]

local Curl = require("plenary.curl")
local adapter_utils = require("codecompanion.adapters.utils")
local anthropic = require("codecompanion.adapters.http.anthropic")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")

local _cache_expires
local _cached_models

---Return the cached models
---@param opts? table
local function models(opts)
  if opts and opts.last then
    return _cached_models[1]
  end
  return _cached_models
end

---Get a list of available Claude-compatible models from NanoGPT
---@param self CodeCompanion.Adapter
---@param opts? table
---@return table
local function get_models(self, opts)
  if _cached_models and _cache_expires and _cache_expires > os.time() then
    return models(opts)
  end

  _cached_models = {}

  local adapter = require("codecompanion.adapters").resolve(self)
  if not adapter then
    log:error("Could not resolve NanoGPT adapter in the `get_models` function")
    return {}
  end

  adapter_utils.get_env_vars(adapter)
  local url = adapter.env_replaced.url .. adapter.env_replaced.models_endpoint

  local headers = {
    ["content-type"] = "application/json",
  }
  if adapter.env_replaced.api_key then
    headers["Authorization"] = "Bearer " .. adapter.env_replaced.api_key
  end

  local ok, response, json

  ok, response = pcall(function()
    return Curl.get(url, {
      sync = true,
      headers = headers,
      insecure = config.adapters.http.opts.allow_insecure,
      proxy = config.adapters.http.opts.proxy,
    })
  end)
  if not ok then
    log:error("Could not get the NanoGPT models from %s.\nError: %s", url, response)
    return {}
  end

  ok, json = pcall(vim.json.decode, response.body)
  if not ok then
    log:error("Could not parse the response from %s", url)
    return {}
  end

  -- Filter for Claude models only (Haiku and Sonnet)
  for _, model in ipairs(json.data or {}) do
    if model.id then
      local id = model.id:lower()
      if id:match("claude") and (id:match("haiku") or id:match("sonnet")) then
        table.insert(_cached_models, model.id)
      end
    end
  end

_cache_expires = adapter_utils.cache_expiry(config.adapters.http.opts.cache_models_for)

  return models(opts)
end

---@class CodeCompanion.HTTPAdapter.NanoGPTClaude: CodeCompanion.HTTPAdapter
return {
  name = "nanogpt-claude",
  formatted_name = "NanoGPT Claude",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    stream = true,
    tools = true,
    vision = true,
  },
  features = {
    text = true,
    tokens = true,
  },
  temp = {
    input_tokens = 0,
    output_tokens = 0,
  },
  url = "${url}${chat_url}",
  env = {
    api_key = "NANOGPT_API_KEY",
    url = "https://nano-gpt.com/api",
    chat_url = "/v1/messages",
    models_endpoint = "/v1/models",
  },
  headers = {
    ["content-type"] = "application/json",
    ["Authorization"] = "Bearer ${api_key}",
    ["anthropic-beta"] = "prompt-caching-2024-07-31",
  },
  available_tools = anthropic.available_tools,
  handlers = {
    setup = function(self)
      return anthropic.handlers.setup(self)
    end,
    tokens = function(self, data)
      return anthropic.handlers.tokens(self, data)
    end,
    form_parameters = function(self, params, messages)
      return anthropic.handlers.form_parameters(self, params, messages)
    end,
    form_messages = function(self, messages)
      return anthropic.handlers.form_messages(self, messages)
    end,
    form_tools = function(self, tools)
      return anthropic.handlers.form_tools(self, tools)
    end,
    form_reasoning = function(self, data)
      return anthropic.handlers.form_reasoning(self, data)
    end,
    chat_output = function(self, data, tools)
      return anthropic.handlers.chat_output(self, data, tools)
    end,
    inline_output = function(self, data, context)
      return anthropic.handlers.inline_output(self, data, context)
    end,
    on_exit = function(self, data)
      return anthropic.handlers.on_exit(self, data)
    end,
    tools = {
      format_tool_calls = function(self, tools)
        return anthropic.handlers.tools.format_tool_calls(self, tools)
      end,
      output_response = function(self, tool_call, output)
        return anthropic.handlers.tools.output_response(self, tool_call, output)
      end,
    },
  },
  schema = {
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "ID of the Claude model to use via NanoGPT.",
      default = function(self)
        return get_models(self, { last = true })
      end,
      choices = function(self)
        return get_models(self)
      end,
    },
    max_tokens = {
      order = 2,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 4096,
      desc = "The maximum number of tokens to generate before stopping.",
      validate = function(n)
        return n > 0 and n <= 128000, "Must be between 0 and 128000"
      end,
    },
  },
}
