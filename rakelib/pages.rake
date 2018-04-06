# coding: utf-8
require 'yaml'

namespace "pages" do
  desc "Transform special page files with no body to Markdown pages\n" +
       "\n" +
       "Special page files have editable elements in Front Matter.\n" +
       "Editable element Page/Content will become body of new Markdown\n" +
       "file. Other site-specific transformations take place."
  task :html2md do
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
          fm['image'] = fm['editable_elements'].delete 'Page/image'
        else
          fm['editable_elements'].delete 'Page/Title image'
          fm['editable_elements'].delete 'Page/image'
        end
        [f, fm, body] }.
      map {|f, fm, body|
        if fm['editable_elements']['Right column/Title'].strip ==
           'Více ke čtení'
          fm['editable_elements'].delete 'Right column/Title'
        end
        [f, fm, body] }.
      map {|f, fm, body|
        if fm['editable_elements']['Right column/Links'].strip.empty?
          fm['editable_elements'].delete 'Right column/Links'
        end
        [f, fm, body] }.
      map {|f, fm, body|
        body = fm['editable_elements'].delete('Page/Content').strip
        [f, fm, body] }.
      map {|f, fm, body|
        if fm['editable_elements'].empty?
          fm.delete 'editable_elements'
        end
        [f, fm, body] }.
      map {|f, fm, body|
        fm['permalink'] == f[1..('.html'.length - 1)]
        [f, fm, body] }.
      each {|f, fm, body|
        filename = '_md_pages' + File::SEPARATOR +
                   File.basename(f, '.html') + '.md'
        File.write(filename, fm.to_yaml + "---\n" + body + "\n")
        File.unlink f }
  end
end
