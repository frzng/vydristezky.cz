# coding: utf-8
require 'yaml'
require_relative 'util'

PAGES_DIR = '_md_pages'

def md_files
  excluded = [jekyll_config['destination']] + jekyll_config['exclude']
  Dir['**/*.md'].
    reject {|f| excluded.include? f }.
    reject {|f| excluded.any? {|ex| f.start_with? ex } }.
    select {|f| File.file? f }
end

def parsed_md_files
  md_files.
    map {|f| [f] + File.read(f).split(/^---$/, 3) }.
    map {|f, _, fm_raw, body| [f, YAML.load(fm_raw), body] }
end

def scalar_values h
  enum = if h.is_a? Hash then h.values else h end
  enum.
    map {|v| if v.is_a? Enumerable then scalar_values v else v end }.
    flatten
end

def any_strings h, fn
  scalar_values(h).
    select {|v| v.is_a? String }.
    map {|v| send(fn, v) }.
    flatten
end

def match_all md, res
  res.reduce([]) do |res, re|
    pos = 0
    while m = re.match(md, pos)
      res << m[0]
      pos = m.end 0
    end

    res
  end
end

WEIRD_MARKDOWN_RES = [
  /\\/,
  /(?:\r\n|\n){3,}(?!\[[^\]\n]\]:|\z)/m,
  /(?:\r\n|\n){2,}\z/m,
  / +(?:\r\n|\n)?\z/m,
  /\{::\}/,
  /\{:\s+(?!\.wysiwyg-float-(?:left|right)\})/m,
  /"Link: /,
  /^\[[^\]]\]:.+"$/,
  /"\)/,
  /<\/?(?!iframe\b)/i,
  /&\w+;/,
  /\b\p{Zs}$/,
  /\p{Zs}{3,}$/,
  /\p{Zs}{2,}(?!$)/
]

def weird_markdown md
  match_all md, WEIRD_MARKDOWN_RES
end

CZECH_TYPO_RES = [
  /\b[ksvzouai](?: |\r\n|\n)/mi,
  /\p{Nd}+\.?(?: |\r\n|\n)/m,
  /\b\p{L}{1,3}\.(?: |\r\n|\n)/m,
  /\b\p{Ll}{1,3}\.(?: |\r\n|\n)\p{Ll}/m,
  /\b\p{Lu}{1,3}\.(?: |\r\n|\n)\p{Lu}/m,
  /\p{Alnum}+\.\p{Alnum}+/m,
  /\A\p{Ll}[^\b]?\b/,
  /['"”]/,
  /\.{3}/,
  /–$/,
  /\p{Nd}+\.?\b\s*-\s*\p{Nd}+\.?/m,
  /\s+-\s+/m
]

def czech_typo str
  match_all str, CZECH_TYPO_RES
end

namespace "pages" do
  desc "Transform special page files with no body to Markdown pages\n" +
       "\n" +
       "Special page files have editable elements in Front Matter.\n" +
       "Editable element Page/Content will become body of new Markdown\n" +
       "file. Other site-specific transformations take place."
  task html2md: [PAGES_DIR] do
    Dir['./**/*.html'].
      reject {|f| f.start_with?('./node_modules') or
                  f.start_with?('./.') or
                  f.start_with?('./_') }.
      map {|f| [f] + File.read(f).split(/^---$/, 3)[1..2] }.
      map {|f, fm_raw, body| [f, YAML.load(fm_raw), body.strip] }.
      select {|_, _, body| body.empty? }.
      select {|_, fm, _| fm['editable_elements'] and
                         fm['editable_elements']['Page/Content'] }.
      map {|f, fm, body|
        if fm['editable_elements']['header/Search'].strip == 'Hledat...'
          fm['editable_elements'].delete 'header/Search'
        end
        [f, fm, body] }.
      map {|f, fm, body|
        fm['title'].strip!
        if fm['title'] == fm['editable_elements']['Page/Title'].strip
          fm['editable_elements'].delete 'Page/Title'
        elsif fm['editable_elements']['Page/Title']
          fm['editable_elements']['Page/Title'].strip!
        end
        [f, fm, body] }.
      map {|f, fm, body|
        if fm['editable_elements']['Page/Title image'] == 'true'
          fm['editable_elements'].delete 'Page/Title image'
        else
          fm['editable_elements'].delete 'Page/Title image'
          fm['editable_elements'].delete 'Page/image'
        end
        [f, fm, body] }.
      map {|f, fm, body|
        if fm['editable_elements']['Right column/Title'] and
           (fm['editable_elements']['Right column/Title'].strip ==
              'Více ke čtení' or
            fm['editable_elements']['Right column/Title'].strip ==
              'Dále ke čtení')
          fm['editable_elements'].delete 'Right column/Title'
        elsif fm['editable_elements']['Right column/Title']
          fm['editable_elements']['Right column/Title'].strip!
        end
        [f, fm, body] }.
      map {|f, fm, body|
        if fm['editable_elements']['Right column/Links'] and
           fm['editable_elements']['Right column/Links'].strip.empty?
          fm['editable_elements'].delete 'Right column/Links'
        end
        [f, fm, body] }.
      map {|f, fm, body|
        body = fm['editable_elements'].delete('Page/Content').strip
        [f, fm, body] }.
      map {|f, fm, body|
        fm['permalink'] = f[1...-('.html'.length)]
        [f, fm, body] }.
      map {|f, fm, body|
        fm['layout'] = case fm['layout']
                       when 'withrightcolumn' then 'two_columns_page'
                       when 'withoutrightcolumn' then 'single_column_page'
                       else fm['layout']
                       end
        [f, fm, body] }.
      map {|f, loco_fm, body|
        fm = {}
        fm['title'] = loco_fm['title']
        fm['permalink'] = loco_fm['permalink']
        if loco_fm['editable_elements']['Page/image']
          fm['image'] = loco_fm['editable_elements'].delete 'Page/image'
        end
        if loco_fm['editable_elements']['Page/Title']
          fm['long_title'] = loco_fm['editable_elements'].delete 'Page/Title'
        end
        fm['published'] = if loco_fm.key? 'published'
                            !!loco_fm['published']
                          else
                            true
                          end
        fm['listed'] = if loco_fm.key? 'listed'
                         !!loco_fm['listed']
                       else
                         true
                       end
        fm['position'] = loco_fm['position']
        fm['layout'] = loco_fm['layout']
        if fm['layout'] == 'two_columns_page' and
           loco_fm['editable_elements']['Right column/Title']
          fm['aside_title'] =
            loco_fm['editable_elements'].delete 'Right column/Title'
        end
        if fm['layout'] == 'two_columns_page' and
           loco_fm['editable_elements']['Right column/Links']
          fm['aside_links'] =
            loco_fm['editable_elements'].delete 'Right column/Links'
        end

        [f, fm, body] }.
      each {|f, fm, body|
        filename = PAGES_DIR + File::SEPARATOR +
                   File.basename(f, '.html') + '.md'
        File.write(filename, fm.to_yaml + "---\n" + body + "\n")
        File.unlink f }
  end

  task :list do
    md_files.each {|f| puts f }
  end

  desc "Detect Markdown documents with formatting needing attention\n" +
       "\n" +
       "It looks for escape sequences, kramdown ALDs with exception of\n" +
       "floats from WYSIWYG editor, empty lines and HTML elements."
  task :todo do
    parsed_md_files.
      map {|f, fm, body| ms = any_strings(fm, :weird_markdown) +
                              weird_markdown(body)
                         [f, ms] }.
      reject {|f, ms| ms.empty? }.
      each {|f, ms| ms.each {|m| puts "#{f}: #{m.inspect}" } }
  end

  desc "Detect candidates for fixes according to Czech convention\n" +
       "\n" +
       "Czech grammar describes where should be non-braking\n" +
       "spaces. Sometimes it requires deeper understanding of the context."
  task :czech_typo do
    parsed_md_files.
      map {|f, fm, body| ms = any_strings(fm, :czech_typo) +
                              czech_typo(body)
                         [f, ms] }.
      reject {|f, ms| ms.empty? }.
      each {|f, ms| ms.each {|m| puts "#{f}: #{m.inspect}" } }
  end

  directory PAGES_DIR
end
