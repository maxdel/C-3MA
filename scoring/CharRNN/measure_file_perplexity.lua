require 'torch'
require 'nn'
require 'nngraph'
require 'optim'
require 'lfs'

require 'util.OneHot'
require 'util.misc'

cmd = torch.CmdLine()
cmd:text()
cmd:text('Measure the perplexity of a character-level language model on some test corpus')
cmd:text()
cmd:text('Options')
-- required:
cmd:argument('-model','model checkpoint to evaluate')
-- optional parameters
cmd:option('-data_path','data/tinyshakespeare/input.txt','path to the data file for calculating perplexity')
cmd:option('-seed',123,'random number generator\'s seed')
cmd:option('-temperature',1,'temperature of sampling')
cmd:option('-gpuid',0,'which gpu to use. -1 = use CPU')
cmd:option('-opencl',0,'use OpenCL (instead of CUDA)')
cmd:option('-verbose',1,'set to 0 to ONLY print the sampled text, no diagnostics')
cmd:text()

-- parse input params
opt = cmd:parse(arg)

-- gated print: simple utility function wrapping a print
function gprint(str)
    if opt.verbose == 1 then print(str) end
end

--------------------------------------------------------
-- see if the file exists
function file_exists(file)
  local f = io.open(file, "rb")
  if f then f:close() end
  return f ~= nil
end

-- get all lines from a file, returns an empty 
-- list/table if the file does not exist
function lines_from(file)
  if not file_exists(file) then return {} end
  lines = {}
  for line in io.lines(file) do 
    lines[#lines + 1] = line
  end
  return lines
end

-- tests the functions above
local lines = lines_from(opt.data_path)
--------------------------------------------------------

-- check that cunn/cutorch are installed if user wants to use the GPU
if opt.gpuid >= 0 and opt.opencl == 0 then
    local ok, cunn = pcall(require, 'cunn')
    local ok2, cutorch = pcall(require, 'cutorch')
    if not ok then gprint('package cunn not found!') end
    if not ok2 then gprint('package cutorch not found!') end
    if ok and ok2 then
        cutorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
        cutorch.manualSeed(opt.seed)
    else
        opt.gpuid = -1 -- overwrite user setting
    end
end

-- check that clnn/cltorch are installed if user wants to use OpenCL
if opt.gpuid >= 0 and opt.opencl == 1 then
    local ok, cunn = pcall(require, 'clnn')
    local ok2, cutorch = pcall(require, 'cltorch')
    if not ok then print('package clnn not found!') end
    if not ok2 then print('package cltorch not found!') end
    if ok and ok2 then
        cltorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
        torch.manualSeed(opt.seed)
    else
        opt.gpuid = -1 -- overwrite user setting
    end
end

-- load the model checkpoint
if not lfs.attributes(opt.model, 'mode') then
    gprint('Error: File ' .. opt.model .. ' does not exist. Are you sure you didn\'t forget to prepend cv/ ?')
end
checkpoint = torch.load(opt.model)
protos = checkpoint.protos
protos.rnn:evaluate() -- put in eval mode so that dropout works properly

-- initialize the vocabulary (and its inverted version)
local vocab = checkpoint.vocab
local ivocab = {}
for c,i in pairs(vocab) do ivocab[i] = c end

-- initialize the rnn state to all zeros
local current_state
current_state = {}
for L = 1,checkpoint.opt.num_layers do
    -- c and h for all layers
    local h_init = torch.zeros(1, checkpoint.opt.rnn_size):double()
    if opt.gpuid >= 0 and opt.opencl == 0 then h_init = h_init:cuda() end
    if opt.gpuid >= 0 and opt.opencl == 1 then h_init = h_init:cl() end
    table.insert(current_state, h_init:clone())
    if checkpoint.opt.model == 'lstm' then
        table.insert(current_state, h_init:clone())
    end
end
state_size = #current_state

prediction = torch.Tensor(1, #ivocab):fill(1)/(#ivocab)
if opt.gpuid >= 0 and opt.opencl == 0 then prediction = prediction:cuda() end
if opt.gpuid >= 0 and opt.opencl == 1 then prediction = prediction:cl() end


-- print all line numbers and their contents
for k,v in pairs(lines) do
	prev_char = nil
	N = 0
	qs = {}
	for c in string.gmatch(v, ".") do
		N = N + 1
		if curr_char == nil then
			curr_char = torch.Tensor(1)
			if vocab[c] ~= nil then
				curr_char[1] = vocab[c]
			end
		else
			prev_char = curr_char
			curr_char = torch.Tensor(1)
			if vocab[c] ~= nil then
				curr_char[1] = vocab[c]
				prediction:div(opt.temperature) -- scale by temperature
				local probs = torch.exp(prediction):squeeze()
				probs:div(torch.sum(probs)) -- renormalize so probs sum to one
				pred = torch.multinomial(probs:float(), 1):resize(1):float()
				qs[N] = probs[curr_char[1]]
				local lst = protos.rnn:forward{curr_char, unpack(current_state)}
				current_state = {}
				for i=1,state_size do table.insert(current_state, lst[i]) end
				prediction = lst[#lst] -- last element holds the log probabilities
			end
		end
	end
	cross_entropy_per_char = 0
	for i=2,N,1 do
		if qs[i] ~= nil then
			cross_entropy_per_char = cross_entropy_per_char - (math.log(qs[i])/math.log(2))/N
		end
	end
	n_words = 0
	avg_c = 0
	for w in string.gmatch(v, "%S+") do
		n_words = n_words + 1
		avg_c = avg_c + #w
	end
	avg_c = avg_c/n_words
	avg_p = 0
	for i, p in pairs(qs) do
		avg_p = avg_p + p
	end
	avg_p = avg_p/#qs
	cross_entropy_per_word = - (math.log(avg_p^avg_c)/math.log(2))
	
	io.write(k..'\t'..2^cross_entropy_per_word..'\n')
end

