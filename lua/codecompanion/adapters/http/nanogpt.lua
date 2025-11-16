--[[
PLEASE NOTE: This adapter is not supported by CodeCompanion.nvim.
It is simply provided as an example for how you can connect a Claude-compatible endpoint
to CodeCompanion via an adapter. Send any questions or queries to the discussions.
--]]

local Curl = require("plenary.curl")
local adapter_utils = require("codecompanion.utils.adapters")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local openai = require("codecompanion.adapters.http.openai")
local transform = require("codecompanion.utils.tool_transformers")

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
    chat_url = "/v1/messages",
    models_endpoint = "/v1/models",
  },
  headers = {
    ["content-type"] = "application/json",
    ["Authorization"] = "Bearer ${api_key}",
    ["anthropic-beta"] = "prompt-caching-2024-07-31",
  },
  available_tools = {
    ["code_execution"] = {
      description = "The code execution tool allows Claude to run Bash commands and manipulate files, including writing code, in a secure, sandboxed environment",
      ---@param self CodeCompanion.HTTPAdapter.Anthropic
      ---@param tools table The transformed tools table
      callback = function(self, tools)
        self.headers["anthropic-beta"] = (self.headers["anthropic-beta"] .. "," or "") .. "code-execution-2025-08-25"

        table.insert(tools, {
          type = "code_execution_20250825",
          name = "code_execution",
        })
      end,
    },
    ["memory"] = {
      description = "Enables Claude to store and retrieve information across conversations through a memory file directory. Claude can create, read, update, and delete files that persist between sessions, allowing it to build knowledge over time without keeping everything in the context window",
      ---@param self CodeCompanion.HTTPAdapter.Anthropic
      ---@param tools table The transformed tools table
      callback = function(self, tools)
        self.headers["anthropic-beta"] = (self.headers["anthropic-beta"] .. "," or "")
          .. "context-management-2025-06-27"

        table.insert(tools, {
          type = "memory_20250818",
          name = "memory",
        })
      end,
      opts = {
        -- Allow a hybrid tool -> One that also has a client side implementation
        client_tool = "strategies.chat.tools.memory",
      },
    },
    ["web_fetch"] = {
      description = "The web fetch tool allows Claude to retrieve full content from specified web pages and PDF documents.",
      ---@param self CodeCompanion.HTTPAdapter.Anthropic
      ---@param tools table The transformed tools table
      callback = function(self, tools)
        self.headers["anthropic-beta"] = (self.headers["anthropic-beta"] .. "," or "") .. "web-fetch-2025-09-10"

        table.insert(tools, {
          type = "web_fetch_20250910",
          name = "web_fetch",
          max_uses = 5,
        })
      end,
    },
    ["web_search"] = {
      description = "The web search tool gives Claude direct access to real-time web content, allowing it to answer questions with up-to-date information beyond its knowledge cutoff",
      ---@param self CodeCompanion.HTTPAdapter.Anthropic
      ---@param tools table The transformed tools table
      callback = function(self, tools)
        table.insert(tools, {
          type = "web_search_20250305",
          name = "web_search",
          max_uses = 5,
        })
      end,
    },
  },
  handlers = {
    ---@param self CodeCompanion.HTTPAdapter
    ---@return boolean
    setup = function(self)
      if self.opts and self.opts.stream then
        self.parameters.stream = true
        self.parameters.stream_options = { include_usage = true }
      end
      return true
    end,

    tokens = function(self, data)
      return openai.handlers.tokens(self, data)
    end,
    form_parameters = function(self, params, messages)
      return openai.handlers.form_parameters(self, params, messages)
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
          if schema._meta and schema._meta.adapter_tool then
            if self.available_tools[schema.name] then
              self.available_tools[schema.name].callback(self, transformed)
            end
          else
            table.insert(transformed, transform.to_anthropic(schema))
          end
        end
      end

      return { tools = transformed }
    end,
    ---Reset accumulated output when starting a new request
    ---@param self CodeCompanion.HTTPAdapter
    on_start = function(self)
      self._accumulated_output = nil
      -- Use compatible time function
      local uv = vim.uv or vim.loop
      self._request_start_time = uv and uv.now() or (os.time() * 1000)
      return true
    end,
    ---Output the data from the API ready for insertion into the chat buffer
    ---@param self CodeCompanion.HTTPAdapter
    ---@param data table The streamed JSON data from the API, also formatted by the format_data handler
    ---@param tools? table The table to write any tool output to
    ---@return table|nil [status: string, output: table]
    chat_output = function(self, data, tools)
      local output = {}

      if self.opts.stream then
        -- Safety check: if request has been running too long, force completion
        if self._request_start_time then
          local uv = vim.uv or vim.loop
          local current_time = uv and uv.now() or (os.time() * 1000)
          if (current_time - self._request_start_time) > 30000 then
            return {
              status = "success",
              output = self._accumulated_output or { content = "Request completed." },
            }
          end
        end
        
        if type(data) == "string" and string.sub(data, 1, 6) == "event:" then
          -- Parse SSE format
          local lines = vim.split(data, "\n")
          for _, line in ipairs(lines) do
            if string.sub(line, 1, 6) == "event:" then
              local event = string.match(line, "event:%s*(.+)")
              if event == "message_stop" then
                -- Signal stream completion but don't return empty output
                if not self._content_sent then
                  self._content_sent = true
                  return {
                    status = "success",
                    output = self._accumulated_output or { content = "" },
                  }
                end
              elseif event == "error" then
                -- Handle streaming errors
                return {
                  status = "error",
                  output = {
                    role = "assistant",
                    content = "I encountered a streaming error. Please try your request again.",
                  },
                }
              end
            elseif string.sub(line, 1, 5) == "data:" then
              local json_str = string.match(line, "data:%s*(.+)")
              if json_str and json_str ~= "" then
                -- Check for direct message_stop data
                if string.match(json_str, '"stop_reason"') then
                  return {
                    status = "success",
                    output = self._accumulated_output or { content = "" },
                  }
                end
                
                local ok, json = pcall(vim.json.decode, json_str, { luanil = { object = true } })
                if ok then
                  -- Check for message_stop in data as well
                  if json.type == "message_stop" or (json.delta and json.delta.stop_reason) then
                    return {
                      status = "success",
                      output = self._accumulated_output or { content = "" },
                    }
                  end
                  
                  -- Initialize accumulated output if not exists
                  self._accumulated_output = self._accumulated_output or {}
                  
                  -- Process the JSON data
                  if json.type == "message_start" then
                    self._accumulated_output.role = json.message.role
                    self._accumulated_output.content = ""
                  elseif json.type == "content_block_start" then
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
                    if json.delta.type == "text_delta" then
                      if not self._content_sent then
                        self._accumulated_output.content = (self._accumulated_output.content or "") .. json.delta.text
                        -- Return partial content for real-time display
                        return {
                          status = "partial",
                          output = {
                            role = self._accumulated_output.role,
                            content = self._accumulated_output.content,
                          },
                        }
                      end
                    elseif json.delta.type == "input_json_delta" and tools then
                      for i, tool in ipairs(tools) do
                        if tool._index == json.index then
                          tools[i].input = tools[i].input .. json.delta.partial_json
                          break
                        end
                      end
                    end
                  elseif json.type == "content_block_stop" and tools then
                    -- Finalize tool input when content block stops
                    for i, tool in ipairs(tools) do
                      if tool._index == json.index and tool.input ~= "" then
                        local ok_parse, parsed_input = pcall(vim.json.decode, tool.input)
                        if ok_parse then
                          tool.input = vim.json.encode(parsed_input)
                        end
                        break
                      end
                    end
                  elseif json.type == "message_delta" and json.delta.stop_reason then
                    -- Handle message completion with stop reason
                    if not self._content_sent then
                      self._content_sent = true
                      return {
                        status = "success",
                        output = self._accumulated_output or { content = "" },
                      }
                    end
                  end
                end
              end
            end
          end
          return nil  -- Continue streaming
        else
          -- Handle non-event streaming data
          if data and data ~= "" then
            data = adapter_utils.clean_streamed_data(data)
            local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })
            
            if ok then
              self._accumulated_output = self._accumulated_output or {}
              
              if json.type == "content_block_start" and json.content_block.type == "tool_use" and tools then
                table.insert(tools, {
                  _index = json.index,
                  id = json.content_block.id,
                  name = json.content_block.name,
                  input = "",
                })
              elseif json.type == "content_block_delta" then
                if json.delta.type == "text_delta" then
                  self._accumulated_output.content = (self._accumulated_output.content or "") .. json.delta.text
                  return {
                    status = "partial",
                    output = {
                      role = self._accumulated_output.role or "assistant",
                      content = self._accumulated_output.content,
                    },
                  }
                elseif json.delta.type == "input_json_delta" and tools then
                  for i, tool in ipairs(tools) do
                    if tool._index == json.index then
                      tools[i].input = tools[i].input .. json.delta.partial_json
                      break
                    end
                  end
                end
              elseif json.type == "content_block_stop" and tools then
                for i, tool in ipairs(tools) do
                  if tool._index == json.index and tool.input ~= "" then
                    local ok_parse, parsed_input = pcall(vim.json.decode, tool.input)
                    if ok_parse then
                      tool.input = vim.json.encode(parsed_input)
                    end
                    break
                  end
                end
              elseif json.type == "message_delta" and json.delta.stop_reason then
                -- Ensure completion on message delta with stop reason
                return {
                  status = "success",
                  output = self._accumulated_output or { content = "" },
                }
              end
            end
          end
        end
      end

      -- Handle non-streaming response
      if data and data ~= "" then
        if not self.opts.stream then
          data = data.body
        end

        local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })

        if ok then
          if json.type == "message" then
            output.role = json.role
            output.content = ""
            for i, content in ipairs(json.content or {}) do
              if content.type == "text" then
                output.content = (output.content or "") .. content.text
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
            
            return {
              status = "success",
              output = output,
            }
          elseif json.type == "error" then
            -- Handle API errors gracefully
            local error_msg = json.error and json.error.message or "Unknown API error"
            return {
              status = "error",
              output = {
                role = "assistant",
                content = "I encountered an error: " .. error_msg .. ". Please try your request again.",
              },
            }
          end
        end
      end
    end,

    on_exit = function(self, data)
      -- Ensure proper cleanup and completion signaling
      if self._accumulated_output then
        self._accumulated_output = nil
      end
      
      -- Always return true to signal proper completion
      return true
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
  },
}
