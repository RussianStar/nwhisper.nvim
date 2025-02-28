-- nwhisper.lua
local M = {}
local job_id = nil

--- Detect operating system
local function is_windows()
  return package.config:sub(1,1) == '\\'
end

--- List available audio devices using ffmpeg.
M.list_audio_devices = function()
  local cmd
  local is_win = is_windows()
  
  if is_win then
    cmd = 'ffmpeg -list_devices true -f dshow -i dummy 2>&1'
  else
    cmd = 'ffmpeg -f pulse -list_devices true -i dummy 2>&1'
  end
  
  -- Use vim.fn.system instead of io.popen for better compatibility with Neovim
  print("Executing command: " .. cmd)
  local result = vim.fn.system(cmd)
  
  if vim.v.shell_error ~= 0 then
    print("Command executed with non-zero exit code: " .. vim.v.shell_error)
    -- This is expected as ffmpeg will exit with an error when listing devices
  end
  
  local devices = {}
  
  if is_win then
    -- Windows parsing (DirectShow)
    for line in result:gmatch("[^\r\n]+") do
      -- Look for lines with "(audio)" which indicate audio devices
      if line:find("%(audio%)") then
        -- Extract the device name which is in quotes before "(audio)"
        local device_name = line:match("\"([^\"]+)\"")
        if device_name then
          print("Found Windows audio device: " .. device_name)
          table.insert(devices, device_name)
        end
      end
    end
  else
    -- Linux parsing (PulseAudio)
    for line in result:gmatch("[^\r\n]+") do
      if line:find("'") and line:find("description") then
        local device = line:match("'([^']+)'")
        if device then
          print("Found Linux PulseAudio device: " .. device)
          table.insert(devices, device)
        end
      end
    end
  end

  if #devices == 0 then
    print("No audio devices found. Trying alternative method...")
    
    -- Fallback method for Linux if PulseAudio didn't work
    if not is_win then
      cmd = 'ffmpeg -f alsa -list_devices true -i dummy 2>&1'
      print("Executing fallback command: " .. cmd)
      result = vim.fn.system(cmd)
      
      for line in result:gmatch("[^\r\n]+") do
        if line:find("'") and (line:find("card") or line:find("device")) then
          local device = line:match("'([^']+)'")
          if device then
            print("Found Linux ALSA device: " .. device)
            table.insert(devices, device)
          end
        end
      end
    end
  end

  if #devices == 0 then
    print("No audio devices found.")
  else
    print("Found " .. #devices .. " audio devices")
  end

  return devices
end

--- Record a short audio clip and send to Whisper endpoint for transcription.
M.record_and_transcribe = function()
  local temp_file = os.tmpname() .. ".wav"
  local cmd
  
  print("Recording 5 seconds of audio...")
  
  if is_windows() then
    cmd = string.format(
      'ffmpeg -f dshow -i audio="%s" -ac 1 -ar 16000 -t 5 %s',
      M.audio_device, temp_file
    )
  else
    local input_format = "pulse"
    if M.audio_device:find("card") or M.audio_device:find("hw:") then
      input_format = "alsa"
    end
    
    cmd = string.format(
      'ffmpeg -f %s -i "%s" -ac 1 -ar 16000 -t 5 %s',
      input_format, M.audio_device, temp_file
    )
  end
  
  vim.fn.system(cmd)
  print("Recording complete. Transcribing...")
  
  -- Build URL for the transcription API (using HTTP POST, not WebSocket)
  local url = string.format(
    "%s/v1/audio/transcriptions",
    M.whisper_endpoint
  )
  
  -- Use curl to send the WAV file to the API
  local curl_cmd = string.format(
    'curl -X POST %s -F "file=@%s" -F "model=Systran/faster-distil-whisper-large-v3" -F "response_format=text"',
    url, temp_file
  )
  
  print("Executing transcription command: " .. curl_cmd)
  local result = vim.fn.system(curl_cmd)
  print("Transcription result: " .. result)
  
  -- Insert the transcribed text at the current cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_set_text(0, cursor_pos[1] - 1, cursor_pos[2], cursor_pos[1] - 1, cursor_pos[2], {result})
  
  -- Clean up temporary file
  os.remove(temp_file)
  
  return result
end

--- Start audio streaming and send to Whisper endpoint using WebSockets.
M.start_streaming = function()
  -- Create a temporary script file
  local script_file = os.tmpname() .. ".py"
  
  -- Write a Python script to handle WebSocket streaming
  local script_content = [[
import asyncio
import websockets
import sys
import json
import subprocess
import threading
import queue

# WebSocket URL
ws_url = "]] .. string.format(
    "ws://%s/v1/audio/transcriptions?model=%s&language=%s&response_format=%s&temperature=%s",
    M.whisper_endpoint:gsub("^http://", ""),
    "Systran/faster-distil-whisper-large-v3",
    "en",
    "json",
    "0"
  ) .. [["

# Audio device
audio_device = "]] .. M.audio_device .. [["

# Queue for audio data
audio_queue = queue.Queue()

# Function to capture audio
def capture_audio():
    if sys.platform == "win32":
        # Windows
        cmd = [
            "ffmpeg", "-loglevel", "quiet", "-f", "dshow", 
            "-i", f"audio={audio_device}", "-ac", "1", "-ar", "16000", 
            "-f", "s16le", "-"
        ]
    else:
        # Linux
        input_format = "pulse"
        if "card" in audio_device or "hw:" in audio_device:
            input_format = "alsa"
        
        cmd = [
            "ffmpeg", "-loglevel", "quiet", "-f", input_format, 
            "-i", audio_device, "-ac", "1", "-ar", "16000", 
            "-f", "s16le", "-"
        ]
    
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    
    try:
        while True:
            # Read audio data in chunks
            chunk = process.stdout.read(8000)  # 0.25 seconds of audio at 16kHz, 16-bit mono
            if not chunk:
                break
            audio_queue.put(chunk)
    except Exception as e:
        print(f"Error capturing audio: {e}", file=sys.stderr)
    finally:
        process.terminate()
        process.wait()

# Start audio capture in a separate thread
def start_audio_capture():
    thread = threading.Thread(target=capture_audio)
    thread.daemon = True
    thread.start()
    return thread

# Main WebSocket client
async def websocket_client():
    print("Connecting to WebSocket...")
    async with websockets.connect(ws_url) as websocket:
        print("WebSocket connected")
        
        # Start audio capture
        audio_thread = start_audio_capture()
        
        # Send audio data
        send_task = asyncio.create_task(send_audio(websocket))
        
        # Receive transcription
        receive_task = asyncio.create_task(receive_transcription(websocket))
        
        # Wait for both tasks to complete
        await asyncio.gather(send_task, receive_task)

# Send audio data to WebSocket
async def send_audio(websocket):
    try:
        while True:
            try:
                # Get audio chunk from queue with timeout
                chunk = audio_queue.get(timeout=1)
                await websocket.send(chunk)
            except queue.Empty:
                # No audio data available, continue
                await asyncio.sleep(0.1)
    except websockets.exceptions.ConnectionClosed:
        print("WebSocket connection closed")

# Receive transcription from WebSocket
async def receive_transcription(websocket):
    try:
        async for message in websocket:
            try:
                # Try to parse as JSON
                data = json.loads(message)
                if "text" in data:
                    print(data["text"])
            except json.JSONDecodeError:
                # Not JSON, print as is
                print(message)
    except websockets.exceptions.ConnectionClosed:
        print("WebSocket connection closed")

# Run the WebSocket client
asyncio.run(websocket_client())
]]

  -- Write the script to a file
  local script_handle = io.open(script_file, "w")
  script_handle:write(script_content)
  script_handle:close()
  
  -- Execute the Python script
  local cmd = string.format("python %s", script_file)
  print("Starting WebSocket streaming with Python: " .. cmd)
  
  job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and #line > 0 then
            print("Transcription: " .. line)
            
            -- Insert the transcribed text at the current cursor position
            local cursor_pos = vim.api.nvim_win_get_cursor(0)
            vim.api.nvim_buf_set_text(0, cursor_pos[1] - 1, cursor_pos[2], cursor_pos[1] - 1, cursor_pos[2], {line})
            
            -- Move the cursor to the end of the inserted text
            vim.api.nvim_win_set_cursor(0, {cursor_pos[1], cursor_pos[2] + #line})
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and #line > 0 then
            print("Python error: " .. line)
          end
        end
      end
    end,
    on_exit = function()
      print("WebSocket streaming stopped")
      
      -- Clean up temporary file
      os.remove(script_file)
      
      job_id = nil
    end,
  })
  
  if job_id <= 0 then
    print("Failed to start WebSocket streaming")
    os.remove(script_file)
  else
    print("WebSocket streaming started")
  end
end

--- Stop the audio streaming process.
M.stop_streaming = function()
  if job_id then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
end

--- Select an audio device using Telescope.
M.select_audio_device = function()
  local devices = M.list_audio_devices()
  
  -- Use the standard Telescope picker instead of fzf which might not be available
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  
  pickers.new({}, {
    prompt_title = "Select Audio Device",
    finder = finders.new_table({
      results = devices,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()[1]
        M.audio_device = selection
        print("Selected audio device: " .. M.audio_device)
      end)
      return true
    end,
  }):find()
end

--- Setup default keybindings and configurations for starting and stopping the streaming process.
-- This function should be called in the user's init.lua to configure the plugin.
M.setup = function(config)
  config = config or {}
  local start_key = config.start_key or '<leader>as'
  local stop_key = config.stop_key or '<leader>ap'
  local select_key = config.select_key or '<leader>ad'
  local record_key = config.record_key or '<leader>ar'
  local whisper_endpoint = config.whisper_endpoint or 'http://192.168.178.188:8000'
  local audio_device = config.audio_device or '"Microphone (Realtek High Definition Audio)"'

  -- Use vim.keymap.set (newer API) instead of vim.api.nvim_set_keymap
  vim.keymap.set('n', start_key, function() require("nwhisper").start_streaming() end, { desc = 'Start audio streaming' })
  vim.keymap.set('n', stop_key, function() require("nwhisper").stop_streaming() end, { desc = 'Stop audio streaming' })
  vim.keymap.set('n', select_key, function() require("nwhisper").select_audio_device() end, { desc = 'Select audio device' })
  vim.keymap.set('n', record_key, function() require("nwhisper").record_and_transcribe() end, { desc = 'Record and transcribe audio' })

  M.whisper_endpoint = whisper_endpoint
  M.audio_device = audio_device
end

return M
