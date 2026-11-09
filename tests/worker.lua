local config = require('pele_mermaid.config').normalize({})
local renderer = require('pele_mermaid.deps.renderer')
local runtime = require('pele_mermaid.deps.runtime')
local worker = require('pele_mermaid.deps.worker')
local root = vim.fn.tempname()
vim.fn.mkdir(root,'p')
local function run()
  local results, calls = {}, {}
  local function callback(name)
    return function(result)
      calls[name]=(calls[name] or 0)+1
      results[name]=result
    end
  end
  local instance = renderer.new(config.renderer)
  local theme = require('pele_mermaid.theme').resolve(config)
  local function render(source, name)
    return instance:render({ source = source, output = 'svg', theme = theme.name, options = theme.options }, callback(name))
  end
  local operation = render('flowchart LR\nA[Cancelled]-->B', 'cancelled')
  operation.cancel()
  render('not Mermaid', 'invalid')
  render('flowchart LR\nA[Newest]-->B[Visible]', 'latest')
  render('flowchart LR\nA[Portable]-->B', 'export')
  assert(vim.wait(15000,function() return results.cancelled and results.invalid and results.latest and results.export end,10),'worker requests stalled')
  assert(results.cancelled.cancelled and not results.cancelled.ok,'cancelled request must report cancellation')
  assert(not results.invalid.ok and results.invalid.error,'invalid request must fail independently')
  assert(results.latest.ok and results.latest.output:find('Newest',1,true),'latest source must own its reply')
  assert(results.latest.output:find('data:font/woff2',1,true),'shared SVG artifacts must be font-portable')
  assert(results.export.ok and results.export.output:find('Portable',1,true)
    and results.export.output:find('data:font/woff2',1,true),'large fragmented export must retain source and fonts')
  for _, count in pairs(calls) do assert(count==1,'request callback delivered more than once') end

  local command = assert(runtime.resolve(config))
  local script = root..'/worker.mjs'
  vim.fn.writefile({
    'import { createInterface } from "node:readline";',
    'for await (const line of createInterface({input:process.stdin})) {',
    '  const {id,request}=JSON.parse(line);',
    '  if (request.hang) await new Promise(() => {});',
    '  if (request.delay) await new Promise(resolve => setTimeout(resolve,request.delay));',
    '  if (request.corrupt) { process.stdout.write("not-json\\n"); continue; }',
    '  process.stdout.write(JSON.stringify({id,result:{output:request.output || "recovered worker"}})+"\\n");',
    '}',
  },script)
  worker.request(command,script,'{"hang":true}',100,callback('timeout'))
  worker.request(command,script,'{}',5000,callback('waiting'))
  assert(vim.wait(10000,function() return results.timeout and results.waiting end,10),'queued worker was not restarted')
  assert(not results.timeout.ok and results.waiting.ok,
    'active timeout must not fail an unsent queued request')
  worker.request(command,script,'{}',5000,callback('recovered'))
  assert(vim.wait(10000,function() return results.recovered end,10),'replacement worker did not stay warm')
  assert(results.recovered.ok and results.recovered.output=='recovered worker')
  assert(calls.timeout==1 and calls.waiting==1,'worker exit must not repeat timeout callbacks')

  -- Together these renders exceed one request deadline, but each execution fits.
  worker.request(command,script,'{"delay":350,"output":"serial first"}',600,callback('serial_first'))
  worker.request(command,script,'{"delay":350,"output":"serial second"}',600,callback('serial_second'))
  assert(vim.wait(5000,function() return results.serial_first and results.serial_second end,10))
  assert(results.serial_first.ok and results.serial_second.ok,
    'a queued request must receive its full execution deadline')

  local cancel_active = worker.request(command,script,'{"hang":true}',5000,callback('cancel_active'))
  worker.request(command,script,'{}',5000,callback('after_cancel'))
  assert(cancel_active() and not cancel_active())
  assert(vim.wait(10000,function() return results.after_cancel end,10))
  assert(results.cancel_active.cancelled and results.after_cancel.ok,
    'cancelling the active request must preserve unrelated queued work')

  worker.request(command,script,'{"delay":150}',5000,callback('before_queued_cancel'))
  local cancel_queued = worker.request(command,script,'{"hang":true}',5000,callback('cancel_queued'))
  worker.request(command,script,'{}',5000,callback('after_queued_cancel'))
  assert(cancel_queued())
  assert(vim.wait(10000,function() return results.before_queued_cancel and results.after_queued_cancel end,10))
  assert(results.before_queued_cancel.ok and results.after_queued_cancel.ok and results.cancel_queued.cancelled)

  worker.request(command,script,'{"corrupt":true}',5000,callback('corrupt'))
  worker.request(command,script,'{}',5000,callback('after_corrupt'))
  assert(vim.wait(10000,function() return results.corrupt and results.after_corrupt end,10))
  assert(not results.corrupt.ok and results.after_corrupt.ok,
    'corrupt active replies must fail once and restart only unsent queued work')
  for _, count in pairs(calls) do assert(count==1,'request callback delivered more than once') end
  worker.request(command,script,'{}',5000,callback('stopped'))
  worker.stop(command,script,'test stopped')
  assert(results.stopped and results.stopped.error=='test stopped','stop must release pending worker requests')
  instance:stop('test complete')
  print('PASS: warm rendering, fragmented font exports, serial execution deadlines, isolated cancellation/timeouts and worker replacement')
end
local ok, err=xpcall(run,debug.traceback)
vim.fn.delete(root,'rf')
if not ok then io.stderr:write(err..'\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')
