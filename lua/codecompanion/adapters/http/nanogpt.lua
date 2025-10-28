--[[
PLEASE NOTE: This adapter is not supported by CodeCompanion.nvim.
It is simply provided as an example for how you can connect a Claude-compatible endpoint
to CodeCompanion via an adapter. Send any questions or queries to the discussions.
--]]

local Curl = require("plenary.curl")
local adapter_utils = require("codecompanion.utils.adapters")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local tokens = require("codecompanion.utils.tokens")
local transform = require("codecompanion.utils.tool_transformers")

local input_tokens = 0
local output_tokens = 0

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

---Get a list of available Claude-compatible models from NanoGPT
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
    log:error("Could not resolve NanoGPT Claude adapter in the `get_models` function")
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
    log:error("Could not get the NanoGPT Claude models from " .. url .. ".\nError: %s", response)
    return {}
  end

  ok, json = pcall(vim.json.decode, response.body)
  if not ok then
    log:error("Could not parse the response from " .. url)
    return {}
  end

  -- Filter for Claude models only
  for _, model in ipairs(json.data) do
if model.id and (
  (model.id:lower():match("claude") and model.id:lower():match("haiku")) or
  (model.id:lower():match("claude") and model.id:lower():match("sonnet"))
) then
      table.insert(_cached_models, model.id)
    end
  end

  _cache_expires = adapter_utils.refresh_cache(_cache_file, config.adapters.http.opts.cache_models_for)

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
  features = {
    tokens = true,
    text = true,
  },
  opts = {
    cache_breakpoints = 4, -- Cache up to this many messages
    cache_over = 300, -- Cache any message which has this many tokens or more
    stream = true,
    tools = true,
    vision = true,
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
  },
  temp = {},
  handlers = {
    ---@param self CodeCompanion.HTTPAdapter
    ---@return boolean
    setup = function(self)
       log:debug("[NanoGPT] Setup started")

      if self.opts and self.opts.stream then
        self.parameters.stream = true
      end

      -- Make sure the individual model options are set
      local model = self.schema.model.default
      if type(model) == "function" then
        model = model(self)
      end
       log:debug("[NanoGPT] Using model: %s", model)

      local model_opts = self.schema.model.choices
      if type(model_opts) == "function" then
        model_opts = model_opts(self)
      end
      if model_opts and model_opts[model] and model_opts[model].opts then
        self.opts = vim.tbl_deep_extend("force", self.opts, model_opts[model].opts)
         log:debug("[NanoGPT] Model options: %s", model_opts[model].opts)
        if not model_opts[model].opts.has_vision then
          self.opts.vision = false
        end
      end

      -- Reset temp values to prevent issues with unsupported features
      self.temp = self.temp or {}

      -- Only enable extended features if the model supports them
      local current_model_opts = model_opts and model_opts[model] and model_opts[model].opts
      if not (current_model_opts and current_model_opts.can_reason) then
        self.temp.extended_thinking = false
        self.temp.extended_output = false
        self.temp.thinking_budget = nil
      end

       log:debug("[NanoGPT] Setup completed successfully")
      return true
    end,

    ---Set the parameters
    ---@param self CodeCompanion.HTTPAdapter
    ---@param params table
    ---@param messages table
    ---@return table
    form_parameters = function(self, params, messages)
      -- Only add thinking parameters if the model supports reasoning
      local model = self.schema.model.default
      if type(model) == "function" then
        model = model(self)
      end
      local model_opts = self.schema.model.choices
      if type(model_opts) == "function" then
        model_opts = model_opts(self)
      end
      local current_model_opts = model_opts and model_opts[model] and model_opts[model].opts

      if current_model_opts and current_model_opts.can_reason then
        if self.temp.extended_thinking and self.temp.thinking_budget then
          params.thinking = {
            type = "enabled",
            budget_tokens = self.temp.thinking_budget,
          }
        end
        if self.temp.extended_thinking then
          params.temperature = 1
        end
      end

      return params
    end,

    ---Set the format of the role and content for the messages that are sent from the chat buffer to the LLM
    ---@param self CodeCompanion.HTTPAdapter
    ---@param messages table Format is: { { role = "user", content = "Your prompt here" } }
    ---@return table
    form_messages = function(self, messages)
      local has_tools = false

      -- 1. Extract and format system messages
      local system = vim
        .iter(messages)
        :filter(function(msg)
          return msg.role == "system"
        end)
        :map(function(msg)
          return {
            type = "text",
            text = msg.content,
            cache_control = nil, -- To be set later if needed
          }
        end)
        :totable()
      system = next(system) and system or nil

      -- 2. Remove any system messages from the regular messages
      messages = vim
        .iter(messages)
        :filter(function(msg)
          return msg.role ~= "system"
        end)
        :totable()

      -- 3–7. Clean up, role‐convert, and handle tool calls in one pass
      messages = vim.tbl_map(function(m)
        -- 3. Account for any images
        if m._meta and m._meta.tag == "image" and m.context and m.context.mimetype then
          if self.opts and self.opts.vision then
            m.content = {
              {
                type = "image",
                source = {
                  type = "base64",
                  media_type = m.context.mimetype,
                  data = m.content,
                },
              },
            }
          else
            -- Remove the message if vision is not supported
            return nil
          end
        end

        -- 4. Remove disallowed keys
        m = adapter_utils.filter_out_messages({
          message = m,
          allowed_words = {
            "content",
            "role",
            "reasoning",
            "tools",
          },
        })

        -- 5. Turn string content into { { type = "text", text } } and add in the reasoning
        if m.role == self.roles.user or m.role == self.roles.llm then
          -- Anthropic doesn't allow the user to submit an empty prompt. But
          -- this can be necessary to prompt the LLM to analyze any tool
          -- calls and their output
          if m.role == self.roles.user and m.content == "" then
            m.content = "<prompt></prompt>"
          end

          if type(m.content) == "string" then
            m.content = {
              { type = "text", text = m.content },
            }
          end
        end

        if m.tools and m.tools.calls and vim.tbl_count(m.tools.calls) > 0 then
          has_tools = true
        end

        -- 6. Treat 'tool' role as user and convert tool results to Anthropic format
        if m.role == "tool" then
          m.role = self.roles.user
          -- Convert tool result from CodeCompanion format to Anthropic format
          if m.tools and m.tools.type == "tool_result" then
            -- Handle content that might already be in Anthropic's format
            if type(m.content) == "table" and m.content.type == "tool_result" then
              -- Already in Anthropic format, keep it as-is but ensure it's in an array
              m.content = { m.content }
            else
              -- Convert from CodeCompanion format to Anthropic format
              m.content = {
                {
                  type = "tool_result",
                  tool_use_id = m.tools.call_id,
                  content = m.content,
                  is_error = m.tools.is_error or false,
                },
              }
            end
            m.tools = nil
          end
        end

        -- 7. Convert any LLM tool_calls into content blocks
        if has_tools and m.role == self.roles.llm and m.tools and m.tools.calls then
          m.content = m.content or {}
          for _, call in ipairs(m.tools.calls) do
            local args = call["function"].arguments
            table.insert(m.content, {
              type = "tool_use",
              id = call.id,
              name = call["function"].name,
              input = args ~= "" and vim.json.decode(args) or vim.empty_dict(),
            })
          end
          m.tools = nil
        end

        -- 8. If reasoning is present, format it as a content block
        if m.reasoning and type(m.content) == "table" then
          -- Ref: https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking#how-extended-thinking-works
          table.insert(m.content, 1, {
            type = "thinking",
            thinking = m.reasoning.content,
            signature = m.reasoning._data.signature,
          })
        end

        return m
      end, messages)

      -- 9. Merge consecutive messages with the same role
      messages = adapter_utils.merge_messages(messages)

      -- 10. Ensure that any consecutive tool results are merged and text messages are included
      if has_tools then
        for _, m in ipairs(messages) do
          if m.role == self.roles.user and m.content and m.content ~= "" then
            -- Check if content is already an array of blocks
            if type(m.content) == "table" and m.content.type then
              -- If it's a single content block (like a tool_result), make it an array
              m.content = { m.content }
            end

            -- Now we can iterate over the content blocks
            if type(m.content) == "table" and vim.islist(m.content) then
              local consolidated = {}
              for _, block in ipairs(m.content) do
                if block.type == "tool_result" then
                  local prev = consolidated[#consolidated]
                  if prev and prev.type == "tool_result" and prev.tool_use_id == block.tool_use_id then
                    -- Merge consecutive tool results with the same tool_use_id
                    prev.content = prev.content .. block.content
                  else
                    table.insert(consolidated, block)
                  end
                else
                  table.insert(consolidated, block)
                end
              end
              m.content = consolidated
            end
          end
        end
      end

      -- 11+. Cache large messages per opts.cache_over / cache_breakpoints
      local breakpoints_used = 0
      for i = #messages, 1, -1 do
        local msgs = messages[i]
        if msgs.role == self.roles.user then
          -- Loop through the content
          for _, msg in ipairs(msgs.content) do
            if msg.type ~= "text" or msg.text == "" then
              goto continue
            end
            if
              tokens.calculate(msg.text) >= self.opts.cache_over and breakpoints_used < self.opts.cache_breakpoints
            then
              msg.cache_control = { type = "ephemeral" }
              breakpoints_used = breakpoints_used + 1
            end
            ::continue::
          end
        end
      end
      if system and breakpoints_used < self.opts.cache_breakpoints then
        for _, prompt in ipairs(system) do
          if breakpoints_used < self.opts.cache_breakpoints then
            prompt.cache_control = { type = "ephemeral" }
            breakpoints_used = breakpoints_used + 1
          end
        end
      end

      return { system = system, messages = messages }
    end,

    ---Form the reasoning output that is stored in the chat buffer
    ---@param self CodeCompanion.HTTPAdapter
    ---@param data table The reasoning output from the LLM
    ---@return nil|{ content: string, _data: table }
    form_reasoning = function(self, data)
      local content = vim
        .iter(data)
        :map(function(item)
          return item.content
        end)
        :filter(function(content)
          return content ~= nil
        end)
        :join("")

      local signature = data[#data].signature

      return {
        content = content,
        _data = {
          signature = signature,
        },
      }
    end,

    ---Provides the schemas of the tools that are available to the LLM to call
    ---@param self CodeCompanion.HTTPAdapter
    ---@param tools table<string, table>
    ---@return table|nil
    form_tools = function(self, tools)
      if not self.opts.tools or not tools then
        return
      end

      local transformed = {}
      for _, tool in pairs(tools) do
        for _, schema in pairs(tool) do
          table.insert(transformed, transform.to_anthropic(schema))
        end
      end

      return { tools = transformed }
    end,

    ---Returns the number of tokens generated from the LLM
    ---@param self CodeCompanion.HTTPAdapter
    ---@param data table The data from the LLM
    ---@return number|nil
    tokens = function(self, data)
      if data then
        if self.opts.stream then
          data = adapter_utils.clean_streamed_data(data)
        else
          data = data.body
        end
        local ok, json = pcall(vim.json.decode, data)

        if ok then
          if json.type == "message_start" then
            input_tokens = (json.message.usage.input_tokens or 0)
              + (json.message.usage.cache_creation_input_tokens or 0)

            output_tokens = json.message.usage.output_tokens or 0
          elseif json.type == "message_delta" then
            return (input_tokens + output_tokens + json.usage.output_tokens)
          elseif json.type == "message" then
            return (json.usage.input_tokens + json.usage.output_tokens)
          end
        end
      end
    end,

    ---Output the data from the API ready for insertion into the chat buffer
    ---@param self CodeCompanion.HTTPAdapter
    ---@param data table The streamed JSON data from the API, also formatted by the format_data handler
    ---@param tools? table The table to write any tool output to
    ---@return table|nil [status: string, output: table]
    chat_output = function(self, data, tools)
      local output = {}

      if self.opts.stream then
        if type(data) == "string" and string.sub(data, 1, 6) == "event:" then
          return
        end

          -- Check for error responses in streaming mode
          if type(data) == "string" and data:match('"type":"error"') then
            local ok, json = pcall(vim.json.decode, data:match('^{.-}'))
            if ok and json.type == "error" and json.error then
              log:error("NanoGPT API Error: %s (code: %s)", json.error.message or "Unknown error", json.error.code or "unknown")
              return {
                status = "error",
                output = { error = json.error.message or "API request failed" }
              }
            end
          end
      end

      if data and data ~= "" then
        if self.opts.stream then
          data = adapter_utils.clean_streamed_data(data)
        else
          data = data.body
        end

        local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })

        if ok then
          if json.type == "message_start" then
            output.role = json.message.role
            output.content = ""
          elseif json.type == "content_block_start" then
            if json.content_block.type == "thinking" then
              output.reasoning = output.reasoning or {}
              output.reasoning.content = ""
            end
            if json.content_block.type == "tool_use" and tools then
              -- Source: https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview#single-tool-example
              table.insert(tools, {
                _index = json.index,
                id = json.content_block.id,
                name = json.content_block.name,
                input = "",
              })
            end
          elseif json.type == "content_block_delta" then
            if json.delta.type == "thinking_delta" then
              output.reasoning = output.reasoning or {}
              output.reasoning.content = json.delta.thinking
            elseif json.delta.type == "signature_delta" then
              output.reasoning = output.reasoning or {}
              output.reasoning.signature = json.delta.signature
            else
              output.content = json.delta.text
              if json.delta.partial_json and tools then
                for i, tool in ipairs(tools) do
                  if tool._index == json.index then
                    tools[i].input = tools[i].input .. json.delta.partial_json
                    break
                  end
                end
              end
            end
          elseif json.type == "message" then
            output.role = json.role

            for i, content in ipairs(json.content) do
              if content.type == "text" then
                output.content = (output.content or "") .. content.text
              elseif content.type == "thinking" then
                output.reasoning = output.reasoning and output.reasoning or {}
                output.reasoning.content = content.text
              elseif content.type == "tool_use" and tools then
                table.insert(tools, {
                  _index = i,
                  id = content.id,
                  name = content.name,
                  -- Encode the input as JSON to match the partial JSON which comes encoded
                  input = vim.json.encode(content.input),
                })
              end
            end
          end

          return {
            status = "success",
            output = output,
          }
        end
      end
    end,

    ---Output the data from the API ready for inlining into the current buffer
    ---@param self CodeCompanion.HTTPAdapter
    ---@param data table The streamed JSON data from the API, also formatted by the format_data handler
    ---@param context? table Useful context about the buffer to inline to
    ---@return table|nil
    inline_output = function(self, data, context)
      if self.opts.stream then
        return log:error("Inline output is not supported for non-streaming models")
      end

      if data and data ~= "" then
        local ok, json = pcall(vim.json.decode, data.body, { luanil = { object = true } })

        if not ok then
          log:error("Error decoding JSON: %s", data.body)
          return { status = "error", output = json }
        end

        if ok then
          if json.type == "message" then
            if json.content[2] then
              return { status = "success", output = json.content[2].text }
            end
            return { status = "success", output = json.content[1].text }
          end
        end
      end
    end,

    tools = {
      ---Format the LLM's tool calls for inclusion back in the request
      ---@param self CodeCompanion.HTTPAdapter
      ---@param tools table The raw tools collected by chat_output
      ---@return table|nil
      format_tool_calls = function(self, tools)
        -- Convert to the OpenAI format
        local formatted = {}
        for _, tool in ipairs(tools) do
          local formatted_tool = {
            _index = tool._index,
            id = tool.id,
            type = "function",
            ["function"] = {
              name = tool.name,
              arguments = tool.input,
            },
          }
          table.insert(formatted, formatted_tool)
        end
        return formatted
      end,

      ---Output the LLM's tool call so we can include it in the messages
      ---@param self CodeCompanion.HTTPAdapter
      ---@param tool_call {id: string, function: table, name: string}
      ---@param output string
      ---@return table
      output_response = function(self, tool_call, output)
        return {
          -- The role should actually be "user" but we set it to "tool" so that
          -- in the form_messages handler it's easier to identify and merge
          -- with other user messages.
          role = "tool",
          content = output,
          tools = {
            type = "tool_result",
            call_id = tool_call.id,
            is_error = false,
          },
          -- Chat Buffer option: To tell the chat buffer that this shouldn't be visible
          opts = { visible = false },
        }
      end,
    },

    ---Function to run when the request has completed. Useful to catch errors
    ---@param self CodeCompanion.HTTPAdapter
    ---@param data? table
    ---@return nil
    on_exit = function(self, data)
      if data and data.status >= 400 then
        log:error("Error %s: %s", data.status, data.body)
      end
    end,
  },
  schema = {
    ---@type CodeCompanion.Schema
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "The Claude model that will complete your prompt from NanoGPT.",
      default = function(self)
        local models = get_models(self, { last = true })
        return models and #models > 0 and models or "claude-3-5-sonnet-20241022"
      end,
      choices = function(self)
        local models_list = get_models(self) or {}
        if type(models_list) ~= "table" then
          models_list = {}
        end
        local choices = {}
        for _, model in ipairs(models_list) do
          if type(model) ~= "string" then
            goto continue
          end
          -- Add basic options for all models
          choices[model] = {
            formatted_name = model:gsub("%-", " "):gsub("(%w)(%w*)", function(first, rest)
              return first:upper() .. rest
            end),
            opts = { has_vision = true },
          }

          -- Add reasoning capabilities only for models explicitly named with "thinking"
          local model_lower = model:lower()
          if model_lower:match("thinking") or model_lower:match("reasoner") then
            choices[model].opts.can_reason = true
          end

          -- Add token efficient tools for 3.7 sonnet (more flexible pattern matching)
          if model_lower:match("3.*7.*sonnet") then
            choices[model].opts.has_token_efficient_tools = true
          end
          ::continue::
        end
        -- Ensure we always have at least one fallback model
        if next(choices) == nil then
          choices["claude-3-5-sonnet-20241022"] = {
            formatted_name = "Claude 3.5 Sonnet",
            opts = { has_vision = true },
          }
        end
        return choices
      end,
    },
    ---@type CodeCompanion.Schema
    extended_output = {
      order = 2,
      mapping = "temp",
      type = "boolean",
      optional = true,
      default = false,
      desc = "Enable larger output context (128k tokens). Only available with claude-3-7-sonnet models.",
      ---@param self CodeCompanion.HTTPAdapter
      condition = function(self)
        local model = self.schema.model.default
        if type(model) == "function" then
          model = model(self)
        end
        local choices = self.schema.model.choices
        if type(choices) == "function" then
          choices = choices(self)
        end
        if choices and choices[model] and choices[model].opts then
          return choices[model].opts.can_reason
        end
        return false
      end,
    },
    ---@type CodeCompanion.Schema
    extended_thinking = {
      order = 3,
      mapping = "temp",
      type = "boolean",
      optional = true,
      desc = "Enable extended thinking for more thorough reasoning. Requires thinking_budget to be set.",
      default = false, -- Default to false to prevent issues with unsupported models
      ---@param self CodeCompanion.HTTPAdapter
      condition = function(self)
        local model = self.schema.model.default
        if type(model) == "function" then
          model = model(self)
        end
        local choices = self.schema.model.choices
        if type(choices) == "function" then
          choices = choices(self)
        end
        if choices and choices[model] and choices[model].opts then
          return choices[model].opts.can_reason
        end
        return false
      end,
    },
    ---@type CodeCompanion.Schema
    thinking_budget = {
      order = 4,
      mapping = "temp",
      type = "number",
      optional = true,
      default = 16000,
      desc = "The maximum number of tokens to use for thinking when extended_thinking is enabled. Must be less than max_tokens.",
      validate = function(n)
        return n > 0, "Must be greater than 0"
      end,
      ---@param self CodeCompanion.HTTPAdapter
      condition = function(self)
        local model = self.schema.model.default
        if type(model) == "function" then
          model = model(self)
        end
        local choices = self.schema.model.choices
        if type(choices) == "function" then
          choices = choices(self)
        end
        if choices and choices[model] and choices[model].opts then
          return choices[model].opts.can_reason
        end
        return false
      end,
    },
    ---@type CodeCompanion.Schema
    max_tokens = {
      order = 5,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 4096, -- Conservative default for all models
      desc = "The maximum number of tokens to generate before stopping. This parameter only specifies the absolute maximum number of tokens to generate. Different models have different maximum values for this parameter.",
      validate = function(n)
        return n > 0 and n <= 128000, "Must be between 0 and 128000"
      end,
    },
    ---@type CodeCompanion.Schema
    temperature = {
      order = 6,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0,
      desc = "Amount of randomness injected into the response. Ranges from 0.0 to 1.0. Use temperature closer to 0.0 for analytical / multiple choice, and closer to 1.0 for creative and generative tasks. Note that even with temperature of 0.0, the results will not be fully deterministic.",
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1.0"
      end,
    },
    ---@type CodeCompanion.Schema
    top_p = {
      order = 7,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = nil,
      desc = "Computes the cumulative distribution over all the options for each subsequent token in decreasing probability order and cuts it off once it reaches a particular probability specified by top_p",
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1"
      end,
    },
    ---@type CodeCompanion.Schema
    top_k = {
      order = 8,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = nil,
      desc = "Only sample from the top K options for each subsequent token. Use top_k to remove long tail low probability responses",
      validate = function(n)
        return n >= 0, "Must be greater than 0"
      end,
    },
    ---@type CodeCompanion.Schema
    stop_sequences = {
      order = 9,
      mapping = "parameters",
      type = "list",
      optional = true,
      default = nil,
      subtype = {
        type = "string",
      },
      desc = "Sequences where the API will stop generating further tokens",
      validate = function(l)
        return #l >= 1, "Must have more than 1 element"
      end,
    },
  },
}
