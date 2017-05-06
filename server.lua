local http = require('http')
local url = require('url')
local fs = require('fs')
local sql = require('sqlite3')
local mimes = require('libs.mimes')
local template = require('libs.template')
template.caching(false)
local json = require('json')
local query = require('querystring')
local Response = require('http').ServerResponse

function string:split(chars) local t = {} self:gsub('([^'..chars..']+)', function(m) table.insert(t, m) end) return t end

function string:random(len)
  local r = ''
  for i=1,(len or 8) do
    local rn = math.random(1, #self)
    r = r..self:sub(rn, rn)
  end
  return r
end

function string:charset()
  local pat = '^['..self..']$'
  local cs = ''
  for i=0,127 do
    local char = string.char(i)
    if char:match(pat) then
      cs = cs .. char
    end
  end
  return cs
end

local charset = ('%a%d'):charset()

local options = {
  appname = 'Lastbin',
  durations = {
    {"5 minutes", 5*60},
    {"1 hour", 60*60},
    {"1 day", 24*60*60},
    {"1 month", 31*24*60*60},
    {"Forever", 0},
    {"Self-destruct", -1}
  },
  privacy = {
    {"Public", 1},
    {"Private", 2},
    {"Unlisted", 3}
  },
  languages = {
    "Plain Text",
    "Lua",
    "C",
    "JavaScript"
  }
}

function getType(path)
  return mimes[path:lower():match("[^.]*$")] or mimes.default
end

function getValue(t, k)
  for _, v in ipairs(t) do
    if v[1] == k then
      return v[2]
    end
  end
  return
end

--[[ Response function helpers ]]

function Response:say(data, dtype, code)
  self:writeHead(code or 200, {
    ['Content-Type'] = dtype or 'text/plain',
    ['Content-Length'] = #(data or '')
  })
  self:write(data or '')
end

function Response:notFound(reason)
  self:writeHead(404, {
    ["Content-Type"] = "text/plain",
    ["Content-Length"] = #reason
  })
  self:write(reason)
end

function Response:error(reason)
  self:writeHead(500, {
    ["Content-Type"] = "text/plain",
    ["Content-Length"] = #reason
  })
  self:write(reason)
end

function Response:redirect(url, cookie)
  local b = string.format([=[
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=%s" />
    ]=]..(cookie and '<meta http-equiv="set-cookie" content="'..cookie..'">' or '')..[=[
  </head>
</html>]=], url)
  self:writeHead(500, {
    ["Content-Type"] = 'text/html',
    ["Content-Length"] = #b
  })
  self:write(b)
end

local db = sql.open('lastbin.db')
db[[
CREATE TABLE IF NOT EXISTS pastes(
  id TEXT,
  name TEXT,
  author INTEGER,
  folder INTEGER,
  privacy INTEGER,
  expire INTEGER,
  encrypted TEXT,
  lang TEXT,
  paste TEXT,
  created INTEGER
);

CREATE TABLE IF NOT EXISTS users(
  id INTEGER,
  username TEXT,
  password TEXT,
  recovery TEXT,
  joined TEXT,
  approved INTEGER
);

CREATE TABLE IF NOT EXISTS folders(
  id INTEGER,
  owner INTEGER,
  name TEXT
);

CREATE TABLE IF NOT EXISTS sessions(
  id INTEGER,
  cookie TEXT,
  created TEXT
);
]]

function dbdo(db, s, ...)
  return db:prepare(s):reset():bind(...):step()
end

function cleanPastes()
  dbdo(db, "DELETE FROM pastes WHERE expire <= ? AND expire > 0;", os.time())
end
cleanPastes()

function makeSession(id)
  local token
  repeat
    token = charset:random(30)
  until not dbdo(db, 'SELECT id FROM sessions WHERE cookie == ?', token)
  dbdo(db, 'INSERT INTO sessions VALUES(?, ?, ?)', id, token,os.time())
  return token
end

local root = 'www'
http.createServer(function(req, res)

  local chunks = ""
  req:on ('data', function (chunk, len)
    chunks = chunks .. chunk
  end)

  req:on('end', function()
    req.uri = url.parse(req.url)
    local path = req.uri.pathname
    local token, user = (getValue(req.headers, 'Cookie') or ''):match('token%s-=%s-(['..charset..']+)')
    p('token', token)
    p('path', path)
    if token then
      local uid = unpack(dbdo(db, "SELECT id FROM sessions WHERE cookie == ?", token) or {})
      p('uid', uid)
      if uid then
        user = dbdo(db, "SELECT * FROM users WHERE id == ?", uid)
      end
    end
    
----------------------------------------------------------
    if path == '/api/paste' then -- Submit paste
      local data = query.parse(chunks)

      if not data.name or #data.name == 0 then data.name = 'Untitled' end
      data.expire = data.expire and tonumber(data.expire) or 1
      data.privacy = data.privacy and tonumber(data.privacy) or 1
      data.key = data.key or 'false'
      data.language = options.languages[data.language] or 'Plain Text'
      data.data  = data.data or ''
      if #data.data == 0 then res:redirect('/') end
      
      local id
      repeat -- Finding an unused ID
        id = charset:random()
      until not dbdo(db, 'SELECT id FROM pastes WHERE id == ?', id)

      local time = os.time() + options.durations[data.expire][2]
      dbdo(db, 'INSERT INTO pastes VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        id, data.name, 0, 0, data.privacy, time,
        tostring(data.encrypted == 'true'), data.language, data.data, os.time())
      res:redirect('/paste/'..id)
----------------------------------------------------------
    elseif path:match('^/paste/['..charset..']+') then -- Paste read page
      cleanPastes()
      local pid, opt = path:match('^/paste/(['..charset..']+)/?(.*)')
      local paste = dbdo(db, 'SELECT * FROM pastes WHERE id == ?', pid)
      if not paste then
        return res:redirect('/')
      end
      
      local paste = {
        name = paste[2],
        author = paste[3],
        authorUser = dbdo(db, 'SELECT * FROM users WHERE id == ?', tonumber(paste[3])),
        --folder = paste[4],
        privacy = paste[5],
        expire = paste[6] - os.time(),
        encrypted = paste[7] == 'true',
        language = paste[8],
        data = paste[9],
        created = paste[10] - os.time()
      }
      
      if paste.author ~= 0 and paste.privacy == 3 and uid ~= paste.author then
        return redirect('/')
      end
      
      if opt == 'raw' then
        return res:say(paste.data)
      else
        res:say(template.compile('tmpl/paste.html')({
          options = options,
          user = user and user[2],
          paste = paste
        }), 'text/html')
      end
----------------------------------------------------------
    elseif path == '/api/signup' and not user then
      local data = query.parse(chunks)
      if not data.username or #data.username == 0 or
         not data.password or #data.password == 0 then
         return res:redirect('/')
      end
      
      if dbdo(db, 'SELECT id FROM users WHERE username == ?', data.username) then
        return res:redirect('/')
      end
      
      local idMax = unpack(dbdo(db, 'SELECT id FROM users ORDER BY id DESC LIMIT 1') or {0})
      dbdo(db, 'INSERT INTO users VALUES(?, ?, ?, ?, ?, ?)', idMax + 1, data.username, data.password, '', os.time(), 0)
      local token = makeSession(idMax + 1)
      res:redirect('/', 'token='..token..';path=/')
----------------------------------------------------------
    elseif path == '/api/signin' and not user then
      local data = query.parse(chunks)

      if not data.username or #data.username == 0 or
         not data.password or #data.password == 0 then
         return res:redirect('/')
      end
      p('signin', data.username)
      p('data', data)
      local user = dbdo(db, 'SELECT id FROM users WHERE username == ? AND password == ?', data.username, data.password)
      p('user', user)
      if user then
        p('found')
        local token = makeSession(user[1])
        res:redirect('/', 'token='..token..';path=/')
      else
        p('no exist')
        res:redirect('/')
      end
----------------------------------------------------------
    elseif path == '/api/signout' and user then
      local data = query.parse(chunks)
      dbdo(db, 'DELETE FROM sessions WHERE cookie == ?', token)
      res:redirect('/', 'token=;path=/')
----------------------------------------------------------
    elseif path == '/' then -- New paste / Homepage
      res:say(template.compile('tmpl/index.html')({
        options = options,
        user = user and user[2]
      }), 'text/html')
----------------------------------------------------------
    else -- Every other requests
      path = root..path
      fs.stat(path, function (err, stat)
        if err then
          if err.code == "ENOENT" then
            return res:notFound(err.message .. "\n")
          end
          return res:error((err.message or tostring(err)) .. "\n")
        end
        if stat.type ~= 'file'    then
          return res:notFound("Requested url is not a file\n")
        end
        res:writeHead(200, {
          ["Content-Type"] = getType(path),
          ["Content-Length"] = stat.size
        })
        fs.createReadStream(path):pipe(res)
      end)
    end
  end)
end):listen(42424)

print("Http static file server listening at http://localhost:42424/")
