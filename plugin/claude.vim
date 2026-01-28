vim9script
# File: plugin/claude.vim
# vim: sw=2 ts=2 et

# Configuration variables
if !exists('g:claude_api_key')
  g:claude_api_key = ''
endif

if !exists('g:claude_api_url')
  g:claude_api_url = 'https://api.anthropic.com/v1/messages'
endif

if !exists('g:claude_model')
  g:claude_model = 'claude-opus-4-5-20251101'
endif

if !exists('g:claude_use_bedrock')
  g:claude_use_bedrock = 0
endif

if !exists('g:claude_bedrock_region')
  g:claude_bedrock_region = 'us-west-2'
endif

if !exists('g:claude_bedrock_model_id')
  g:claude_bedrock_model_id = 'us.anthropic.claude-opus-4-5-20251101-v1:0'
endif

if !exists('g:claude_aws_profile')
  g:claude_aws_profile = ''
endif

if !exists('g:claude_map_implement')
  g:claude_map_implement = '<leader>ci'
endif

if !exists('g:claude_map_open_chat')
  g:claude_map_open_chat = '<leader>cc'
endif

if !exists('g:claude_map_send_chat_message')
  g:claude_map_send_chat_message = '<leader><cs>'
endif

if !exists('g:claude_map_cancel_response')
  g:claude_map_cancel_response = '<leader>cx'
endif

# ============================================================================
# Keybindings setup
# ============================================================================

def SetupClaudeKeybindings()

  command! -range -nargs=1 ClaudeImplement <line1>,<line2>call ClaudeImplement(<line1>, <line2>, <q-args>)
  execute "vnoremap " .. g:claude_map_implement .. " :ClaudeImplement<Space>"

  command! ClaudeChat call OpenClaudeChat()
  execute "nnoremap " .. g:claude_map_open_chat .. " :ClaudeChat<CR>"

  command! ClaudeCancel call CancelClaudeResponse()
  execute "nnoremap " .. g:claude_map_cancel_response .. " :ClaudeCancel<CR>"
enddef

augroup ClaudeKeybindings
  autocmd!
  autocmd VimEnter * call SetupClaudeKeybindings()
augroup END

#####################################

var plugin_dir = expand('<sfile>:p:h')

def ClaudeLoadPrompt(prompt_type: string): list<string>
  var prompts_file = plugin_dir .. '/claude_' .. prompt_type .. '_prompt.md'
  return readfile(prompts_file)
enddef

if !exists('g:claude_default_system_prompt')
  g:claude_default_system_prompt = ClaudeLoadPrompt('system')
endif

# Add this near the top of the file, after other configuration variables
if !exists('g:claude_implement_prompt')
  g:claude_implement_prompt = ClaudeLoadPrompt('implement')
endif



# ============================================================================
# Claude API
# ============================================================================

def ClaudeQueryInternal(messages: list<any>, system_prompt: string, tools: list<any>, StreamCallback: func, FinalCallback: func): any
  try
    # Prepare the API request
    var data = {}
    var headers: list<any> = []
    var url = ''

  if g:claude_use_bedrock
    var python_script = plugin_dir .. '/claude_bedrock_helper.py'
    var cmd = ['python3', python_script,
          '--region', g:claude_bedrock_region,
          '--model-id', g:claude_bedrock_model_id,
          '--messages', json_encode(messages),
          '--system-prompt', system_prompt]

    if !empty(g:claude_aws_profile)
      extend(cmd, ['--profile', g:claude_aws_profile])
    endif

    if !empty(tools)
      extend(cmd, ['--tools', json_encode(tools)])
    endif
  else
    url = g:claude_api_url
    data = {
      model: g:claude_model,
      max_tokens: 2048,
      messages: messages,
      stream: v:true
      }
    if !empty(system_prompt)
      data['system'] = system_prompt
    endif
    if !empty(tools)
      data['tools'] = tools
    endif
    extend(headers, ['-H', 'Content-Type: application/json'])
    extend(headers, ['-H', 'x-api-key: ' .. g:claude_api_key])
    # extend(headers, ['-H', 'anthropic-version: 2023-06-01'])
    extend(headers, ['-H', "Authorization: 'Bearer " . g:claude_api_key . '"'])

    # Convert data to JSON
    var json_data = json_encode(data)
    var cmd = ['curl', '-s', '-N', '-X', 'POST']
    extend(cmd, headers)
    extend(cmd, ['-d', json_data, url])
  endif

    # Start the job
    if has('nvim')
      var job = jobstart(cmd, {
        on_stdout: function(HandleStreamOutputNvim, [StreamCallback, FinalCallback]),
        on_stderr: function(HandleJobErrorNvim, [StreamCallback, FinalCallback]),
        on_exit: function(HandleJobExitNvim, [StreamCallback, FinalCallback])
        })
    else
      var job = job_start(cmd, {
        out_cb: function(HandleStreamOutput, [StreamCallback, FinalCallback]),
        err_cb: function(HandleJobError, [StreamCallback, FinalCallback]),
        exit_cb: function(HandleJobExit, [StreamCallback, FinalCallback])
        })
    endif

    return job
  catch
    echohl ErrorMsg
    echomsg "FATAL ERROR in ClaudeQueryInternal: " .. v:exception .. " at " .. v:throwpoint
    echohl None
    return -1
  endtry
enddef

var stored_input_tokens: number

def DisplayTokenUsageAndCost(json_data: string)
  var data = json_decode(json_data)
  if has_key(data, 'usage')
    var usage = data.usage
    var input_tokens = exists('stored_input_tokens') ? stored_input_tokens : get(usage, 'input_tokens', 0)
    var output_tokens = get(usage, 'output_tokens', 0)

    var input_cost = (input_tokens / 1000000.0) * 3.0
    var output_cost = (output_tokens / 1000000.0) * 15.0

    echom printf("Token usage - Input: %d ($%.4f), Output: %d ($%.4f)", input_tokens, input_cost, output_tokens, output_cost)

    if exists('stored_input_tokens')
      unlet stored_input_tokens
    endif
  else
    echom "Error: Invalid JSON data format"
  endif
enddef

var current_tool_call: dict<any>

def HandleStreamOutput(StreamCallback: func, FinalCallback: func, channel: any, msg: string)
  # Split the message into lines
  var lines = split(msg, "\n")
  for line in lines
    # Check if the line starts with 'data:'
    if line =~# '^data:'
      # Extract the JSON data
      var json_str = substitute(line, '^data:\s*', '', '')
      var response = json_decode(json_str)

      if response.type == 'content_block_start' && response.content_block.type == 'tool_use'
        current_tool_call = {
              id: response.content_block.id,
              name: response.content_block.name,
              input: ''
              }
      elseif response.type == 'content_block_delta' && has_key(response.delta, 'type') && response.delta.type == 'input_json_delta'
        if exists('current_tool_call')
          current_tool_call.input ..= response.delta.partial_json
        endif
      elseif response.type == 'content_block_stop'
        if exists('current_tool_call')
          var tool_input = json_decode(current_tool_call.input)
          # XXX this is a bit weird layering violation, we should probably call the callback instead
          AppendToolUse(current_tool_call.id, current_tool_call.name, tool_input)
          unlet current_tool_call
        endif
      elseif has_key(response, 'delta') && has_key(response.delta, 'text')
        var delta = response.delta.text
        StreamCallback(delta)
      elseif response.type == 'message_start' && has_key(response, 'message') && has_key(response.message, 'usage')
        stored_input_tokens = get(response.message.usage, 'input_tokens', 0)
      elseif response.type == 'message_delta' && has_key(response, 'usage')
        DisplayTokenUsageAndCost(json_str)
      elseif response.type != 'message_stop' && response.type != 'message_start' && response.type != 'content_block_start' && response.type != 'ping'
        StreamCallback('Unknown Claude protocol output: "' .. line .. "\"\n")
      endif
    elseif line ==# 'event: ping'
      # Ignore ping events
    elseif line ==# 'event: error'
      StreamCallback('Error: Server sent an error event')
      FinalCallback()
    elseif line ==# 'event: message_stop'
      FinalCallback()
    elseif line !=# 'event: message_start' && line !=# 'event: message_delta' && line !=# 'event: content_block_start' && line !=# 'event: content_block_delta' && line !=# 'event: content_block_stop'
      StreamCallback('Unknown Claude protocol output: "' .. line .. "\"\n")
    endif
  endfor
enddef

def HandleJobError(StreamCallback: func, FinalCallback: func, channel: any, msg: string)
  StreamCallback('Error: ' .. msg)
  FinalCallback()
enddef

def HandleJobExit(StreamCallback: func, FinalCallback: func, job: any, status: number)
  if status != 0
    StreamCallback('Error: Job exited with status ' .. status)
    FinalCallback()
  endif
enddef

def HandleStreamOutputNvim(StreamCallback: func, FinalCallback: func, job_id: any, data: list<any>, event: any)
  for msg in data
    HandleStreamOutput(StreamCallback, FinalCallback, 0, msg)
  endfor
enddef

def HandleJobErrorNvim(StreamCallback: func, FinalCallback: func, job_id: any, data: list<any>, event: any)
  for msg in data
    if msg != ''
      HandleJobError(StreamCallback, FinalCallback, 0, msg)
    endif
  endfor
enddef

def HandleJobExitNvim(StreamCallback: func, FinalCallback: func, job_id: any, exit_code: number, event: any)
  HandleJobExit(StreamCallback, FinalCallback, 0, exit_code)
enddef



# ============================================================================
# Diff View
# ============================================================================

def ApplyChange(normal_command: string, content: string)
  var view = winsaveview()
  var paste_option = &paste

  set paste

  var normal_cmd = substitute(normal_command, '<CR>', "\<CR>", 'g')
  execute 'normal ' .. normal_cmd .. "\<C-r>=content\<CR>"

  &paste = paste_option
  winrestview(view)
enddef

def ApplyCodeChangesDiff(bufnr: number, changes: list<any>)
  var original_winid = win_getid()
  var failed_edits: list<any> = []

  # Find or create a window for the target buffer
  var target_winid = bufwinid(bufnr)
  if target_winid == -1
    # If the buffer isn't in any window, split and switch to it
    execute 'split'
    execute 'buffer ' .. bufnr
    target_winid = win_getid()
  else
    # Switch to the window containing the target buffer
    win_gotoid(target_winid)
  endif

  # Create a new window for the diff view
  rightbelow vnew
  setlocal buftype=nofile
  &filetype = getbufvar(bufnr, '&filetype')

  # Copy content from the target buffer
  setline(1, getbufline(bufnr, 1, '$'))

  # Apply all changes
  for change in changes
    try
      if change.type == 'content'
        ApplyChange(change.normal_command, change.content)
      elseif change.type == 'vimexec'
        for cmd in change.commands
          try
            execute 'normal ' .. cmd
          catch
            execute cmd
          endtry
        endfor
      endif
    catch
      add(failed_edits, change)
      echohl WarningMsg
      echomsg "Failed to apply edit in buffer " .. bufname(bufnr) .. ": " .. v:exception
      echohl None
    endtry
  endfor

  # Set up diff for both windows
  diffthis
  win_gotoid(target_winid)
  diffthis

  # Return to the original window
  win_gotoid(original_winid)

  if !empty(failed_edits)
    echohl WarningMsg
    echomsg "Some edits could not be applied. Check the messages for details."
    echohl None
  endif
enddef



# ============================================================================
# Tool Integration
# ============================================================================

if !exists('g:claude_tools')
  g:claude_tools = [
    {
      name: 'python',
      description: 'Execute a Python one-liner code snippet and return the standard output. NEVER just print a constant or use Python to load the file whose buffer you already see. Use the tool only in cases where a Python program will generate a reliable, precise response than you cannot realistically produce on your own.',
      input_schema: {
        type: 'object',
        properties: {
          code: {
            type: 'string',
            description: 'The Python one-liner code to execute. Wrap the final expression in `print` to see its result - otherwise, output will be empty.'
          }
        },
        required: ['code']
      }
    },
    {
      name: 'shell',
      description: 'Execute a shell command and return both stdout and stderr. Use with caution as it can potentially run harmful commands.',
      input_schema: {
        type: 'object',
        properties: {
          command: {
            type: 'string',
            description: 'The shell command or a short one-line script to execute.'
          }
        },
        required: ['command']
      }
    },
    {
      "name": "open",
      "description": "Open an existing buffer (file, directory or netrw URL) so that you get access to its content. Returns the buffer name, or 'ERROR' for non-existent paths.",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "The path to open, passed as an argument to the vim :edit command"
          }
        },
        "required": ["path"]
      }
    },
    {
      "name": "new",
      "description": "Create a new file, opening a buffer for it so that edits can be applied. Returns an error if the file already exists.",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "The path of the new file to create, passed as an argument to the vim :new command"
          }
        },
        "required": ["path"]
      }
    },
    {
      name: 'open_web',
      description: 'Open a new buffer with the text content of a specific webpage. Use this for accessing documentation or other search results.',
      input_schema: {
        type: 'object',
        properties: {
          url: {
            type: 'string',
            description: 'The URL of the webpage to read'
          },
        },
        required: ['url']
      }
    },
    {
      name: 'web_search',
      description: 'Perform a web search and return the top 5 results. Use this to find information beyond your knowledge on the web (e.g. about specific APIs, new tools or to troubleshoot errors). Strongly consider using open_web next to open one or several result URLs to learn more.',
      input_schema: {
        type: 'object',
        properties: {
          query: {
            type: 'string',
            description: 'The search query (bunch of keywords / keyphrases)'
          },
        },
        required: ['query']
      }
    }
    ]
endif

def ExecuteTool(tool_name: string, arguments: dict<any>): string
  if tool_name == 'python'
    return ExecutePythonCode(arguments.code)
  elseif tool_name == 'shell'
    return ExecuteShellCommand(arguments.command)
  elseif tool_name == 'open'
    return ExecuteOpenTool(arguments.path)
  elseif tool_name == 'new'
    return ExecuteNewTool(arguments.path)
  elseif tool_name == 'open_web'
    return ExecuteOpenWebTool(arguments.url)
  elseif tool_name == 'web_search'
    var escaped_query = py3eval("''.join([c if c.isalnum() or c in '-._~' else '%{:02X}'.format(ord(c)) for c in vim.eval('arguments.query')])")
    return ExecuteOpenWebTool("https://www.google.com/search?q=" .. escaped_query)
  else
    return 'Error: Unknown tool ' .. tool_name
  endif
enddef

def ExecutePythonCode(code: string): string
  redraw
  var confirm = input("Execute this Python code? (y/n/C-C; if you C-C to stop now, you can C-] later to resume) ")
  if confirm =~? '^y'
    var result = system('python3 -c ' .. shellescape(code))
    return result
  else
    return "Python code execution cancelled by user."
  endif
enddef

def ExecuteShellCommand(command: string): string
  redraw
  var confirm = input("Execute this shell command? (y/n/C-C; if you C-C to stop now, you can C-] later to resume) ")
  if confirm =~? '^y'
    var output = system(command)
    var exit_status = v:shell_error
    return output .. "\nExit status: " .. exit_status
  else
    return "Shell command execution cancelled by user."
  endif
enddef

def ExecuteOpenTool(path: string): string
  var current_winid = win_getid()

  topleft :1new

  try
    execute 'edit ' .. fnameescape(path)
    var bufname = bufname('%')

    if line('$') == 1 && getline(1) == ''
      close
      win_gotoid(current_winid)
      return 'ERROR: The opened buffer was empty (non-existent?)'
    else
      win_gotoid(current_winid)
      return bufname
    endif
  catch
    close
    win_gotoid(current_winid)
    return 'ERROR: ' .. v:exception
  endtry
enddef

def ExecuteNewTool(path: string): string
  if filereadable(path)
    return 'ERROR: File already exists: ' .. path
  endif

  var current_winid = win_getid()

  topleft :1new
  execute 'silent write ' .. fnameescape(path)
  var bufname = bufname('%')

  win_gotoid(current_winid)
  return bufname
enddef

def ExecuteOpenWebTool(url: string): string
  var current_winid = win_getid()

  topleft :1new
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile

  execute ':r !elinks -dump ' .. escape(shellescape(url), '%#!')
  if v:shell_error
    close
    win_gotoid(current_winid)
    return 'ERROR: Failed to fetch content from ' .. url .. ': ' .. v:shell_error
  endif

  var bufname = fnameescape(url)
  execute 'file ' .. bufname

  win_gotoid(current_winid)
  return bufname
enddef


# ============================================================================
# ClaudeImplement
# ============================================================================

def LogImplementInChat(instruction: string, implement_response: string, bufname: string, start_line: number, end_line: number)
  var [chat_bufnr, chat_winid, current_winid] = GetOrCreateChatWindow()

  var start_line_text = getline(start_line)
  var end_line_text = getline(end_line)

  if chat_winid != -1
    win_gotoid(chat_winid)
    var indent = GetClaudeIndent()

    # Remove trailing "You:" line if it exists
    var last_line = line('$')
    if getline(last_line) =~ '^You:\s*$'
      execute last_line .. 'delete _'
    endif

    append('$', 'You: Implement in ' .. bufname .. ' (lines ' .. start_line .. '-' .. end_line .. '): ' .. instruction)
    append('$', indent .. start_line_text)
    if end_line - start_line > 1
      append('$', indent .. "...")
    endif
    if end_line - start_line > 0
      append('$', indent .. end_line_text)
    endif
    AppendResponse(implement_response)
    ClosePreviousFold()
    CloseCurrentInteractionCodeBlocks()
    PrepareNextInput()

    win_gotoid(current_winid)
  endif
enddef

var implement_response: string

# Function to implement code based on instructions
def ClaudeImplement(line1: number, line2: number, instruction: string)
  try
    # Validate instruction is not empty
    if empty(trim(instruction))
      echohl ErrorMsg
      echomsg "Error: ClaudeImplement requires an instruction. Usage: :'<,'>ClaudeImplement <your instruction>"
      echohl None
      return
    endif

    # Get the selected code
    var selected_code = join(getline(line1, line2), "\n")
    var bufnr = bufnr('%')
    var bufname = bufname('%')
    var winid = win_getid()

    # Prepare the prompt for code implementation
    var prompt = "<code>\n" .. selected_code .. "\n</code>\n\n"
    prompt ..= join(g:claude_implement_prompt, "\n")

    # Query Claude
    var messages = [{'role': 'user', 'content': instruction}]
    ClaudeQueryInternal(messages, prompt, [],
          function(StreamingImplementResponse),
          function(FinalImplementResponse, [line1, line2, bufnr, bufname, winid, instruction]))
  catch
    echohl ErrorMsg
    echomsg "FATAL ERROR in ClaudeImplement: " .. v:exception .. " at " .. v:throwpoint
    echohl None
  endtry
enddef

def ExtractCodeFromMarkdown(markdown: string): string
  var lines = split(markdown, "\n")
  var in_code_block = 0
  var code: list<string> = []
  for line in lines
    if line =~ '^```'
      in_code_block = !in_code_block
    elseif in_code_block
      add(code, line)
    endif
  endfor
  return join(code, "\n")
enddef

def StreamingImplementResponse(delta: string)
  if !exists("implement_response")
    implement_response = ""
  endif

  implement_response ..= delta
enddef

var current_chat_job: any

def FinalImplementResponse(line1: number, line2: number, bufnr: number, bufname: string, winid: any, instruction: string)
  win_gotoid(winid)

  LogImplementInChat(instruction, implement_response, bufname, line1, line2)

  var implemented_code = ExtractCodeFromMarkdown(implement_response)

  var changes = [{
    type: 'content',
    normal_command: line1 .. 'GV' .. line2 .. 'Gc',
    content: implemented_code
    }]
  ApplyCodeChangesDiff(bufnr, changes)

  echomsg "Apply diff, see :help diffget. Close diff buffer with :q."

  unlet implement_response
  unlet! current_chat_job
enddef



# ============================================================================
# ClaudeChat
# ============================================================================


# ----- Chat service functions

def GetOrCreateChatWindow(): list<any>
  var chat_bufnr = bufnr('Claude Chat')
  if chat_bufnr == -1 || !bufloaded(chat_bufnr)
    OpenClaudeChat()
    chat_bufnr = bufnr('Claude Chat')
  endif

  var chat_winid = bufwinid(chat_bufnr)
  var current_winid = win_getid()

  return [chat_bufnr, chat_winid, current_winid]
enddef

def GetClaudeIndent(): string
  if &expandtab
    return repeat(' ', &shiftwidth)
  else
    return repeat("\t", (&shiftwidth + &tabstop - 1) / &tabstop)
  endif
enddef

def AppendResponse(response: string)
  var response_lines = split(response, "\n")
  if len(response_lines) == 1
    append('$', 'Claude: ' .. response_lines[0])
  else
    append('$', 'Claude:')
    var indent = GetClaudeIndent()
    append('$', mapnew(response_lines, (_, v) => v =~ '^\s*$' ? '' : indent .. v))
  endif
enddef


# ----- Chat window UX

export def GetChatFold(lnum: number): any
  var line = getline(lnum)
  var prev_level = foldlevel(lnum - 1)

  if line =~ '^You:' || line =~ '^System prompt:'
    return '>1'  # Start a new fold at level 1
  elseif line =~ '^\s' || line =~ '^$' || line =~ '^.*:'
    if line =~ '^\s*```'
      if prev_level == 1
        return '>2'  # Start a new fold at level 2 for code blocks
      else
        return '<2'  # End the fold for code blocks
      endif
    else
      return '='   # Use the fold level of the previous line
    endif
  else
    return '0'  # Terminate the fold
  endif
enddef

def SetupClaudeChatSyntax()
  if exists("b:current_syntax")
    return
  endif

  syntax include @markdown syntax/markdown.vim

  syntax region claudeChatSystem start=/^System prompt:/ end=/^\S/me=s-1 contains=claudeChatSystemKeyword
  syntax match claudeChatSystemKeyword /^System prompt:/ contained
  syntax match claudeChatYou /^You:/
  syntax match claudeChatClaude /^Claude\.*:/
  syntax match claudeChatToolUse /^Tool use.*:/
  syntax match claudeChatToolResult /^Tool result.*:/
  syntax region claudeChatClaudeContent start=/^Claude.*:/ end=/^\S/me=s-1 contains=claudeChatClaude,@markdown,claudeChatCodeBlock
  syntax region claudeChatToolBlock start=/^Tool.*:/ end=/^\S/me=s-1 contains=claudeChatToolUse,claudeChatToolResult
  syntax region claudeChatCodeBlock start=/^\s*```/ end=/^\s*```/ contains=@NoSpell

  # Don't make everything a code block; FIXME this works satisfactorily
  # only for inline markdown pieces
  silent! syntax clear markdownCodeBlock

  highlight default link claudeChatSystem Comment
  highlight default link claudeChatSystemKeyword Keyword
  highlight default link claudeChatYou Keyword
  highlight default link claudeChatClaude Keyword
  highlight default link claudeChatToolUse Keyword
  highlight default link claudeChatToolResult Keyword
  highlight default link claudeChatToolBlock Comment
  highlight default link claudeChatCodeBlock Comment

  b:current_syntax = "claudechat"
enddef

def GoToLastYouLine()
  normal! G$
enddef

def OpenClaudeChat()
  var claude_bufnr = bufnr('Claude Chat')

  if claude_bufnr == -1 || !bufloaded(claude_bufnr)
    execute 'botright new Claude Chat'
    setlocal buftype=nofile
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal linebreak

    setlocal foldmethod=expr
    setlocal foldexpr=GetChatFold(v:lnum)
    setlocal foldlevel=1

    SetupClaudeChatSyntax()

    setline(1, ['System prompt: ' .. g:claude_default_system_prompt[0]])
    append('$', mapnew(g:claude_default_system_prompt[1 : ], (_, v) => "\t" .. v))
    append('$', ['Type your messages below, press C-] to send.  (Content of all buffers is shared alongside!)', '', 'You: '])

    # Fold the system prompt
    normal! 1Gzc

    augroup ClaudeChat
      autocmd!
      autocmd BufWinEnter <buffer> call GoToLastYouLine()
    augroup END

    # Add mappings for this buffer
    command! -buffer -nargs=1 SendChatMessage <ScriptCmd>SendChatMessage(<q-args>)
    execute "inoremap <buffer> " .. g:claude_map_send_chat_message .. " <Esc><ScriptCmd>SendChatMessage('Claude:')<CR>"
    execute "nnoremap <buffer> " .. g:claude_map_send_chat_message .. " <ScriptCmd>SendChatMessage('Claude:')<CR>"
  else
    var claude_winid = bufwinid(claude_bufnr)
    if claude_winid == -1
      execute 'botright split'
      execute 'buffer' claude_bufnr
    else
      win_gotoid(claude_winid)
    endif
  endif
  GoToLastYouLine()
enddef


# ----- Chat parser (to messages list)

def AddMessageToList(messages: list<any>, message: dict<any>)
  # FIXME: Handle multiple tool_use, tool_result blocks at once
  if !empty(message.role)
    var msg = {'role': message.role, 'content': join(message.content, "\n")}
    if !empty(message.tool_use)
      msg['content'] = [{'type': 'text', 'text': msg.content}, message.tool_use]
    endif
    if !empty(message.tool_result)
      msg['content'] = [message.tool_result]
    endif
    add(messages, msg)
  endif
enddef

def InitMessage(role: string, line: string): dict<any>
  return {
    role: role,
    content: [substitute(line, '^\S*\s*', '', '')],
    tool_use: {},
    tool_result: {}
  }
enddef

def ParseToolUse(line: string): dict<any>
  var match = matchlist(line, '^Tool use (\(.*\)): \(.*\)$')
  if empty(match)
    return {}
  endif

  return {
    type: 'tool_use',
    id: match[1],
    name: match[2],
    input: {}
  }
enddef

def InitToolResult(line: string): dict<any>
  var match = matchlist(line, '^Tool result (\(.*\)):')
  return {
    role: 'user',
    content: [],
    tool_use: {},
    tool_result: {
      type: 'tool_result',
      tool_use_id: match[1],
      content: ''
    }
  }
enddef

def AppendContent(message: dict<any>, line: string)
  var indent = GetClaudeIndent()
  if !empty(message.tool_use)
    if line =~ '^\s*Input:'
      message.tool_use.input = json_decode(substitute(line, '^\s*Input:\s*', '', ''))
    elseif message.tool_use.name == 'python'
      if !has_key(message.tool_use.input, 'code')
        message.tool_use.input.code = ''
      endif
      message.tool_use.input.code ..= (empty(message.tool_use.input.code) ? '' : "\n") .. substitute(line, '^' .. indent, '', '')
    endif
  elseif !empty(message.tool_result)
    message.tool_result.content ..= (empty(message.tool_result.content) ? '' : "\n") .. substitute(line, '^' .. indent, '', '')
  else
    add(message.content, substitute(substitute(line, '^' .. indent, '', ''), '\s*\[APPLIED\]$', '', ''))
  endif
enddef

def ProcessLine(line: string, messages: list<any>, current_message: dict<any>): dict<any>
  var new_message = copy(current_message)

  if line =~ '^You:'
    AddMessageToList(messages, new_message)
    new_message = InitMessage('user', line)
  elseif line =~ '^Claude'  # both Claude: and Claude...:
    AddMessageToList(messages, new_message)
    new_message = InitMessage('assistant', line)
  elseif line =~ '^Tool use ('
    new_message.tool_use = ParseToolUse(line)
  elseif line =~ '^Tool result ('
    AddMessageToList(messages, new_message)
    new_message = InitToolResult(line)
  elseif !empty(new_message.role)
    AppendContent(new_message, line)
  endif

  return new_message
enddef

def ParseChatBuffer(): list<any>
  var buffer_content = getline(1, '$')
  var messages: list<any> = []
  var current_message = {'role': '', 'content': [], 'tool_use': {}, 'tool_result': {}}
  var system_prompt: list<string> = []
  var in_system_prompt = 0

  for line in buffer_content
    if line =~ '^System prompt:'
      in_system_prompt = 1
      system_prompt = [substitute(line, '^System prompt:\s*', '', '')]
    elseif in_system_prompt && line =~ '^\s'
      add(system_prompt, substitute(line, '^\s*', '', ''))
    else
      in_system_prompt = 0
      current_message = ProcessLine(line, messages, current_message)
    endif
  endfor

  if !empty(current_message.role)
    AddMessageToList(messages, current_message)
  endif

  return [filter(messages, (_, v) => !empty(v.content)), join(system_prompt, "\n")]
enddef


# ----- Sending messages

def GetBuffersContent(): list<any>
  var buffers: list<any> = []
  for bufnr in range(1, bufnr('$'))
    if buflisted(bufnr) && bufname(bufnr) != 'Claude Chat' && !empty(win_findbuf(bufnr))
      var bufname = bufname(bufnr)
      var contents = join(getbufline(bufnr, 1, '$'), "\n")
      add(buffers, {'name': bufname, 'contents': contents})
    endif
  endfor
  return buffers
enddef

def SendChatMessage(prefix: string)
  var [messages, system_prompt] = ParseChatBuffer()

  var tool_uses = ResponseExtractToolUses(messages)
  if !empty(tool_uses)
    for tool_use in tool_uses
      var tool_result = ExecuteTool(tool_use.name, tool_use.input)
      AppendToolResult(tool_use.id, tool_result)
    endfor
    [messages, system_prompt] = ParseChatBuffer()
  endif

  var buffer_contents = GetBuffersContent()
  var content_prompt = "# Contents of open buffers\n\n"
  for buffer in buffer_contents
    content_prompt ..= "Buffer: " .. buffer.name .. "\n"
    content_prompt ..= "<content>\n" .. buffer.contents .. "</content>\n\n"
    content_prompt ..= "============================\n\n"
  endfor

  append('$', prefix .. " ")
  normal! G

  var job = ClaudeQueryInternal(messages, content_prompt .. system_prompt, g:claude_tools, function(StreamingChatResponse), function(FinalChatResponse))

  # Store the job ID or channel for potential cancellation
  if has('nvim')
    current_chat_job = job
  else
    current_chat_job = job_getchannel(job)
  endif
enddef

# Command to send message in normal mode
command! ClaudeSend call SendChatMessage('Claude:')


# ----- Handling responses: Tool use

def ResponseExtractToolUses(messages: list<any>): list<any>
  if len(messages) == 0
    return []
  elseif type(messages[-1].content) == v:t_list
    return filter(copy(messages[-1].content), 'v:val.type == "tool_use"')
  else
    return []
  endif
enddef

def AppendToolUse(tool_call_id: string, tool_name: string, tool_input: dict<any>)
  var indent = GetClaudeIndent()
  # Ensure there's text content before the first tool use
  if getline('$') =~# '^Claude\.*: *$'
    setline('$', 'Claude...: (tool-only response)')
  endif
  append('$', 'Tool use (' .. tool_call_id .. '): ' .. tool_name)
  if tool_name == 'python'
    for line in split(tool_input.code, "\n")
      append('$', indent .. line)
    endfor
  else
    append('$', indent .. 'Input: ' .. json_encode(tool_input))
  endif
  normal! G
enddef

def AppendToolResult(tool_call_id: string, result: string)
  var indent = GetClaudeIndent()
  append('$', 'Tool result (' .. tool_call_id .. '):')
  append('$', mapnew(split(result, "\n"), (_, v) => indent .. v))
  normal! G
enddef


# ----- Handling responses: Code changes

def ProcessCodeBlock(block: dict<any>, all_changes: dict<any>)
  var matches = matchlist(block.header, '^\(\S\+\)\s\+\([^:]\+\)\%(:\(.*\)\)\?$')
  var filetype = get(matches, 1, '')
  var buffername = get(matches, 2, '')
  var normal_command = get(matches, 3, '')

  if empty(buffername)
    echom "Warning: No buffer name specified in code block header"
    return
  endif

  var target_bufnr = bufnr(buffername)

  if target_bufnr == -1
    echom "Warning: Buffer not found for " .. buffername
    return
  endif

  if !has_key(all_changes, target_bufnr)
    all_changes[target_bufnr] = []
  endif

  if filetype ==# 'vimexec'
    add(all_changes[target_bufnr], {
          type: 'vimexec',
          commands: block.code
          })
  else
    if empty(normal_command)
      # By default, append to the end of file
      normal_command = 'Go<CR>'
    endif

    add(all_changes[target_bufnr], {
          type: 'content',
          normal_command: normal_command,
          content: join(block.code, "\n")
          })
  endif

  # Mark the applied code block
  var indent = GetClaudeIndent()
  setline(block.start_line - 1, indent .. '```' .. block.header .. ' [APPLIED]')
enddef

def ResponseExtractChanges(): dict<any>
  var all_changes: dict<any> = {}

  # Find the start of the last Claude block
  normal! G
  var start_line = search('^Claude:', 'b')  # Skip over Claude...:
  var end_line = line('$')
  var markdown_delim = '^' .. GetClaudeIndent() .. '```'

  var in_code_block = 0
  var current_block = {'header': '', 'code': [], 'start_line': 0}

  for line_num in range(start_line, end_line)
    var line = getline(line_num)

    if line =~ markdown_delim
      if ! in_code_block
        # Start of code block
        current_block = {'header': substitute(line, markdown_delim, '', ''), 'code': [], 'start_line': line_num + 1}
        in_code_block = 1
      else
        # End of code block
        current_block.end_line = line_num
        ProcessCodeBlock(current_block, all_changes)
        in_code_block = 0
      endif
    elseif in_code_block
      add(current_block.code, substitute(line, '^' .. GetClaudeIndent(), '', ''))
    endif
  endfor

  # Process any remaining open code block
  if in_code_block
    current_block.end_line = end_line
    ProcessCodeBlock(current_block, all_changes)
  endif

  return all_changes
enddef

def ApplyChangesFromResponse()
  var all_changes = ResponseExtractChanges()
  if !empty(all_changes)
    for [target_bufnr, changes] in items(all_changes)
      ApplyCodeChangesDiff(str2nr(target_bufnr), changes)
    endfor
  endif
  normal! G
enddef


# ----- Handling responses

def ClosePreviousFold()
  var save_cursor = getpos(".")

  normal! G[zk[zzc

  if foldclosed('.') == -1
    echom "Warning: Failed to close previous fold at line " .. line('.')
  endif

  setpos('.', save_cursor)
enddef

def CloseCurrentInteractionCodeBlocks()
  var save_cursor = getpos(".")

  # Move to the start of the current interaction
  normal! [z

  # Find and close all level 2 folds until the end of the interaction
  while 1
    if foldlevel('.') == 2
      normal! zc
    endif

    var current_line = line('.')
    normal! j
    if line('.') == current_line || foldlevel('.') < 1 || line('.') == line('$')
      break
    endif
  endwhile

  setpos('.', save_cursor)
enddef

def PrepareNextInput()
  append('$', '')
  append('$', 'You: ')
  normal! G$
enddef

def StreamingChatResponse(delta: string)
  var [chat_bufnr, chat_winid, current_winid] = GetOrCreateChatWindow()
  win_gotoid(chat_winid)

  var indent = GetClaudeIndent()
  var new_lines = split(delta, "\n", 1)

  if len(new_lines) > 0
    # Update the last line with the first segment of the delta
    var last_line = getline('$')
    setline('$', last_line .. new_lines[0])

    append('$', mapnew(new_lines[1 : ], (_, v) => indent .. v))
  endif

  normal! G
  win_gotoid(current_winid)
enddef

def FinalChatResponse()
  var [chat_bufnr, chat_winid, current_winid] = GetOrCreateChatWindow()
  var [messages, system_prompt] = ParseChatBuffer()
  var tool_uses = ResponseExtractToolUses(messages)

  ApplyChangesFromResponse()

  if !empty(tool_uses)
    SendChatMessage('Claude...:')
  else
    ClosePreviousFold()
    CloseCurrentInteractionCodeBlocks()
    PrepareNextInput()
    win_gotoid(current_winid)
    unlet! current_chat_job
  endif
enddef

def CancelClaudeResponse()
  if exists("current_chat_job")
    if has('nvim')
      jobstop(current_chat_job)
    else
      ch_close(current_chat_job)
    endif
    unlet current_chat_job
    AppendResponse("[Response cancelled by user]")
    ClosePreviousFold()
    CloseCurrentInteractionCodeBlocks()
    PrepareNextInput()
    echo "Claude response cancelled."
  else
    echo "No ongoing Claude response to cancel."
  endif
enddef
