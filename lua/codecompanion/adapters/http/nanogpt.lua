--[[
PLEASE NOTE: This adapter is not supported by CodeCompanion.nvim.
It is simply provided as an example for how you can connect an OpenAI compatible endpoint
to CodeCompanion via an adapter. Send any questions or queries to the discussions.
--]]

local Curl = require("plenary.curl")
local adapter_utils = require("codecompanion.utils.adapters")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local openai = require("codecompanion.adapters.http.openai")

local _cache_expires
local _cache_file = vim.fn.tempname()
local _cached_models

---Return the cached models
---@params opts? table
local function models(opts)
  if opts and opts.last then
    return _cached_models[1]
  end
  return _cached_models
end

---Get a list of available OpenAI compatible models
---@params self CodeCompanion.Adapter
---@params opts? table
---@return table
local function get_models(self, opts)
  if _cached_models and _cache_expires and _cache_expires > os.time() then
    return models(opts)
  end

  _cached_models = {}

  local adapter = require("codecompanion.adapters").resolve(self)
  if not adapter then
    log:error("Could not resolve OpenAI compatible adapter in the `get_models` function")
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
    log:error("Could not get the OpenAI compatible models from " .. url .. ".\nError: %s", response)
    return {}
  end

  ok, json = pcall(vim.json.decode, response.body)
  if not ok then
    log:error("Could not parse the response from " .. url)
    return {}
  end

  for _, model in ipairs(json.data) do
    table.insert(_cached_models, model.id)
  end

  _cache_expires = adapter_utils.refresh_cache(_cache_file, config.adapters.http.opts.cache_models_for)

  return models(opts)
end

---@class CodeCompanion.HTTPAdapter.NanoGPT: CodeCompanion.HTTPAdapter
return {
  name = "nanogpt",
  formatted_name = "NanoGPT",
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
  url = "${url}${chat_url}",
  env = {
    api_key = "NANOGPT_API_KEY",
    url = "https://nano-gpt.com/api",
    chat_url = "/v1/chat/completions",
    models_endpoint = "/v1/models",
  },
  headers = {
    ["Content-Type"] = "application/json",
    Authorization = "Bearer ${api_key}",
  },
  handlers = {
    ---@param self CodeCompanion.HTTPAdapter
    ---@return boolean
    setup = function(self)
      local model = self.schema.model.default
      if type(model) == "function" then
        model = model(self)
      end
      local model_opts = self.schema.model.choices
      if type(model_opts) == "function" then
        model_opts = model_opts(self)
      end

      if model_opts and model_opts[model] and model_opts[model].opts then
        self.opts = vim.tbl_deep_extend("force", self.opts, model_opts[model].opts)
      end

      if self.opts and self.opts.stream then
        self.parameters.stream = true
        self.parameters.stream_options = { include_usage = true }
      end

        -- Reset NanoGPT streaming hygiene state at the start of each request
        self.temp = self.temp or {}
        self.temp.nanogpt = { seen_non_whitespace = false }

      return true
    end,

    tokens = function(self, data)
      return openai.handlers.tokens(self, data)
    end,
    form_parameters = function(self, params, messages)
      return openai.handlers.form_parameters(self, params, messages)
    end,
    form_messages = function(self, messages)
      return openai.handlers.form_messages(self, messages)
    end,
    form_tools = function(self, tools)
      return openai.handlers.form_tools(self, tools)
    end,
      chat_output = function(self, data, tools)
        -- Delegate to OpenAI-compatible handler first
        local result = openai.handlers.chat_output(self, data, tools)
        if not result or result.status ~= "success" or not result.output then
          return result
        end

        local content = result.output.content
        if type(content) == "string" then
          -- Adapter-local streaming hygiene: suppress whitespace/newline-only chunks
          -- and trim leading whitespace from the very first substantive chunk.
          -- Some OpenAI-compatible backends emit many blank tokens before content.
          self.temp = self.temp or {}
          self.temp.nanogpt = self.temp.nanogpt or { seen_non_whitespace = false }

          -- Drop any chunk that's entirely whitespace (spaces, tabs, newlines)
          if content:match("^%s*$") then
            return nil
          end

        -- If this is the first substantive chunk, trim leading whitespace/newlines
        if not self.temp.nanogpt.seen_non_whitespace then
          content = content:gsub("^%s+", "")
          result.output.content = content
          -- If after trimming there's nothing left, drop this chunk too
          if content == "" then
            return nil
          end
        end

          if content:match("%S") then
            self.temp.nanogpt.seen_non_whitespace = true
          end
        end

        return result
      end,
    inline_output = function(self, data, context)
      return openai.handlers.inline_output(self, data, context)
    end,
    tools = {
      format_tool_calls = function(self, tools)
        return openai.handlers.tools.format_tool_calls(self, tools)
      end,
      output_response = function(self, tool_call, output)
        return openai.handlers.tools.output_response(self, tool_call, output)
      end,
    },
    on_exit = function(self, data)
      return openai.handlers.on_exit(self, data)
    end,
  },
  schema = {
    ---@type CodeCompanion.Schema
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "ID of the model to use. See the model endpoint compatibility table for details on which models work with the Chat API.",
      default = function(self)
        return get_models(self, { last = true })
      end,
      choices = function(self)
        return get_models(self)
      end,
    },
    temperature = {
      order = 2,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0,
      desc = "What sampling temperature to use, between 0 and 2.",
      validate = function(n)
        return n >= 0 and n <= 2, "Must be between 0 and 2"
      end,
    },
    max_tokens = {
      order = 3,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = nil,
      desc = "The maximum number of tokens to generate in the chat completion.",
      validate = function(n)
        return n > 0, "Must be greater than 0"
      end,
    },
  },
}
