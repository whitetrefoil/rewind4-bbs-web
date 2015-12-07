fs         = require 'fs-extra'
path       = require 'path'
_          = require 'lodash'
gulp       = require 'gulp'
del        = require 'del'
gulp       = require 'gulp'
ngTemp     = require 'gulp-angular-templatecache'
compass    = require 'gulp-compass'
connect    = require 'gulp-connect'
eslint     = require 'gulp-eslint'
footer     = require 'gulp-footer'
header     = require 'gulp-header'
htmlmin    = require 'gulp-htmlmin'
gIf        = require 'gulp-if'
plumber    = require 'gulp-plumber'
replace    = require 'gulp-replace'
rev        = require 'gulp-rev'
revReplace = require 'gulp-rev-replace'
uglify     = require 'gulp-uglify'
useref     = require 'gulp-useref'
gutil      = require 'gulp-util'
proxy      = require 'http-proxy'
runSeq     = require 'run-sequence'
through2   = require 'through2'
xmlbuilder = require 'xmlbuilder'
argv       = require('yargs')
.alias('p', 'port')
.argv

isDevMode = !argv.ci
isCIMode = argv.ci || false
isReleaseMode = argv.release || false
proxyTarget = argv.proxy || 'localhost:8091'
proxyIsHttps = argv.https || false
proxyServer = null
serverPort = parseInt(argv.p, 10) || 8888
indexPage = 'index.html'
apiPrefix = '/api/'

# Internal Tasks
# -----

# minify html
htmlminPipe = ->
  htmlmin
    collapseBooleanAttributes    : true
    collapseWhitespace           : true
    removeAttributeQuotes        : true
    removeComments               : true
    removeEmptyAttributes        : true
    removeRedundantAttributes    : false  # in case using input[type=text] in CSS
    removeScriptTypeAttributes   : true
    removeStyleLinkTypeAttributes: true

# Bootstrap (fonts)
bootstrapPipe = ->
  gulp.src ['src/lib/bootstrap-sass-official/assets/fonts/bootstrap/**'], { base: 'src/lib/bootstrap-sass-official/assets' }
  .pipe gulp.dest if isDevMode then '.server/css' else '.building/css'
  .pipe gIf !isDevMode, gulp.dest 'dist/css'

gulp.task '_bootstrap', -> bootstrapPipe()


# Compass
compassPipe = ->
  gulp.src 'src/css/**/*.{sass,scss}', { base: 'src' }
  .pipe plumber
    errorHandler: (error) ->
      gutil.log gutil.colors.red('Compass ERROR:'), error.message
      this.emit('end')
  .pipe compass
    config_file: 'compass.rb'
    sass       : 'src/'
    css        : if isDevMode then '.server' else '.building'
    font       : if isDevMode then '.server/css/fonts' else '.building/css/fonts'
    image      : 'src/img'
    bundle_exec: true
    environment: if isDevMode then 'development' else 'production'
    style      : if isReleaseMode then 'compressed' else 'expanded'

gulp.task '_compass', -> compassPipe()


# Angular Templates
ngTempPipe = ->
  gulp.src "src/views/**/*.html", { base: 'src' }
  .pipe htmlminPipe()
  .pipe ngTemp "js/templates.js",
    module: 'dwwj-base-ui'
    base  : path.join __dirname, 'src'
  .pipe gulp.dest '.building'

gulp.task '_ng-temp', -> ngTempPipe()


# HTML
htmlPipe = ->
  gulp.src 'src/*.html'
  .pipe gulp.dest if isDevMode then '.server' else '.building'

gulp.task '_html', -> htmlPipe()


# Misc.
miscPipe = ->
  gulp.src ['src/**/*.*', '!src/**/*.{html,coffee,sass,scss,js}', '!src/lib/**/**'], { base: 'src' }
  .pipe gulp.dest if isDevMode then '.server' else 'dist'

gulp.task '_misc', -> miscPipe()


# Server
gulp.task '_server', ->
  connect.server
    root      : ['.server', 'src']
    port      : serverPort
    livereload: true
    fallback  : "src/#{indexPage}"
    middleware: (connect, opts) ->
      middlewares = []

      # 记录下 API 请求的信息
      middlewares.push (req, res, next) ->
        return next() unless req.url.indexOf(apiPrefix) is 0

        data = ''
        req.on 'data', (chunk) ->
          data += chunk
        req.on 'end', ->
          gutil.log gutil.colors.cyan("#{req.method}:"), req.url
          gutil.log gutil.colors.cyan('BODY:'), data
        next()

      # 使用代理模式
      middlewares.push (req, res, next) ->
        return next() unless proxyServer? and req.url.indexOf(apiPrefix) is 0

        proxyServer.proxyRequest req, res, proxyServer

      # 使用 StubAPI
      middlewares.push (req, res, next) ->
        return next() unless !proxyServer? and req.url.indexOf(apiPrefix) is 0

        fs.readFile "./stubapi/#{req.method.toLowerCase()}/#{req.url.toLowerCase()}.json", { encoding: 'utf8' }, (err, content) ->
          if err?
            gutil.log gutil.colors.yellow "StubAPI \"#{req.url}\" not found"
            res.statusCode = 404
            res.end()
          else
            try
              json = JSON.parse(content)
            catch e
              gutil.log gutil.colors.red "Failed to parse StubAPI file \"#{req.url}\""
              next()
            res.statusCode = json.code or (if req.method is 'POST' then 201 else 200)
            res.setHeader('Content-Type', 'application/json')
            res.end(JSON.stringify(json.body))
            gutil.log gutil.colors.green('StubAPI hit'), req.url

      middlewares


# Proxy
gulp.task '_proxy', ->
  proxyServer = proxy.createProxyServer
    target : "#{if proxyIsHttps then 'https' else 'http'}://#{proxyTarget}"
    xfwd   : true
    headers:
      host  : proxyTarget
      origin: "#{if proxyIsHttps then 'https' else 'http'}://#{proxyTarget}"

  proxyServer.on 'error', (args...) -> console.warn args


# Watch
gulp.task '_watch', ->
  gulp.watch 'src/css/**/*.{sass,scss}', ['_compass']
  gulp.watch 'src/views/**/*.html', ['_ng-temp']
  gulp.watch '.server/**/*.css', ->
    gulp.src '.server/**/*.css'
    .pipe connect.reload()
  gulp.watch ['.server/**/**', '!.server/**/*.css'], ->
    gulp.src ['.server/**/**', '!.server/**/*.css']
    .pipe connect.reload()
  gulp.watch 'src/**/*.{html,js}', ->
    gulp.src 'src/*.html'
    .pipe connect.reload()
  gulp.watch 'src/**/*.js', ['eslint']


# Public Tasks
# -----

# Code Style Checks
gulp.task 'eslint', ->
  pipe = gulp.src ['src/js/**/*.js', 'tests/**/*.js', '!src/js/templates.js']
  .pipe eslint()
  .pipe eslint.format()
  if isCIMode
    pipe = pipe
    .pipe eslint.results (results) ->
      fs.ensureDirSync 'test_results/junit'
      testsuite = xmlbuilder.create('testsuite')
      testsuite.att('name', 'ESLint')
      testsuite.att('package', 'org.eslint')
      testsuite.att('tests', results.length)
      testsuite.att('failures', results.errorCount)
      testsuite.att('warnings', results.warningCount)

      _.forEach results, (file) ->
        testcase = testsuite.ele 'testcase',
          name: file.filePath
          failures: file.errorCount
          warnings: file.warningCount
        messages = _.groupBy(file.messages, 'severity')
        _.forEach messages['1'], (warning) ->
          testcase.ele 'warning',
            type: warning.ruleId
          ,
            """L#{warning.line}:#{warning.column} - #{warning.message}
            Source: `#{warning.source}`\n
            """
          return
        _.forEach messages['2'], (failure) ->
          testcase.ele 'failure',
            type: failure.ruleId
          ,
            """L#{failure.line}:#{failure.column} - #{failure.message}
            Source: `#{failure.source}`\n
            """
          return
        return
      fs.writeFileSync 'test_results/junit/eslint.xml', testsuite.end({pretty: true})
      return results
    .pipe eslint.format 'html', (html) ->
      fs.ensureDirSync 'test_results/html'
      fs.writeFileSync 'test_results/html/eslint.html', html
  return pipe


# Clean
gulp.task 'clean', (cb) ->
  del ['.building', '.compass-cache', '.sass-cache', 'test_results'], cb


# Dev Server
gulp.task 'serve', ['clean'], (cb) ->
  del.sync ['.server']
  runSeq '_bootstrap',
    ['_compass', 'eslint'],
    '_server',
    '_watch',
    cb


# Integration Server
gulp.task 'integration', ['clean'], (cb) ->
  del.sync ['.server']
  runSeq '_bootstrap',
    ['_compass', 'eslint'],
    '_proxy',
    '_server',
    '_watch',
    cb

gulp.task 'it', ['integration']


# Non-release Build
gulp.task 'build', ['clean'], (cb) ->
  isDevMode = false
  del.sync ['dist']

  isJs = (file) ->
    /.*\.js/.test(file.relative) and not /^js\/lib(\.min)?\.js/.test(file.relative)

  runSeq '_bootstrap', [
    '_compass'
    '_ng-temp'
    '_html'
    '_misc'
  ], ->
    pipe = gulp.src '.building/*.html'
    .pipe replace(/<!-- templates: (.*?) -->/g, '$1', {skipBinary: true})
    .pipe useref searchPath: ['.building', 'src']
    .pipe gIf isJs, header('(function() {\n\n')
    .pipe gIf isJs, footer('\n\n}).call();')
    if isReleaseMode
      pipe = pipe
      .pipe gIf isJs, replace('$compileProvider.debugInfoEnabled(true)', '$compileProvider.debugInfoEnabled(false)')
      .pipe gIf '*.js', uglify()
    pipe = pipe
    .pipe gIf ['**/*.{js,css}'], rev()
    .pipe revReplace()
    if isReleaseMode
      pipe = pipe
      .pipe gIf '*.html', replace(/<!-- cnzz: (.*?) -->/g, '$1', {skipBinary: true})
      .pipe gIf '*.html', htmlminPipe()
    pipe
    .pipe gulp.dest 'dist'
    .on 'end', ->
      del ['.building', '.compass-cache', '.sass-cache'], cb


# Release Build
gulp.task 'release', ['clean'], (cb) ->
  isReleaseMode = true
  runSeq 'build', (err) ->
    return cb(err)
