require 'yaml'
require 'uri'
require 'net/http'
require 'fileutils'
require 'date'

require 'bundler'
Bundler.setup :default, :development
require 'locomotive/coal'
require 'kramdown'
require 'nokogiri'

require_relative 'util'


CMS_CONFIG = "#{jekyll_config['source']}/admin/config.yml"
DEPLOY_CONFIG = "#{ENV['WAGON']}/config/deploy.yml"
WAGON_PUBLIC_DIR = "#{ENV['WAGON']}/public"

def wagon_deploy_config
  YAML.load File.read DEPLOY_CONFIG
end

$site_client_semaphore = Mutex.new
def site_client
  $site_client_semaphore.synchronize do
    break @site_client if @site_client

    config = wagon_deploy_config[ENV['DEPLOY_ENV']]

    client = Locomotive::Coal::Client.new config['host'],
                                          email: config['email'],
                                          api_key: config['api_key']
    @site_client = client.scope_by config['handle']
  end
end

$cms_config_semaphore = Mutex.new
def cms_config reload = false
  $cms_config_semaphore.synchronize do
    break @cms_config if @cms_config and not reload

    @cms_config = YAML.load File.read CMS_CONFIG
  end
end

def cms_config!
  cms_config true
end

def ensure_dir dir
  return if File.directory? dir

  $stderr.puts "mkdir -p #{dir}"
  FileUtils.mkdir_p dir
end

def field_to_widget f, content_types
  case f['type']
  when 'text'
    if f['text_formatting'] == 'html'
      ['markdown']
    else
      ['text']
    end
  when 'date'
    ['date', {'format' => 'YYYY-MM-DD'}]
  when 'file'
    ['image']
  when 'belongs_to'
    target = content_types.find {|t| t.slug == f['target'] }
    ['relation', {
       'collection' => target.slug,
       'searchFields' => [target.label_field_name],
       'valueField' => 'slug'
    }]
  when 'has_many'
    [nil]
  when 'many_to_many'
    target = content_types.find do |t|
      t.slug == f['target']
    end
    target_label = target.fields.find do |f|
      f['name'] == target.label_field_name
    end
    ['list', {
       'field' => {
         'name' => target.slug.singularize,
         'label' => target_label['label'],
         'widget' => 'relation',
         'collection' => target.slug,
         'searchFields' => [target_label['name']],
         'valueField' => 'slug'
       }
    }]
  else
    f['type']
  end
end

def unspecialize_name n
  n.gsub /\A_+/, ''
end

def to_netlify_field locomotive_field, content_types
  f = {'name' => locomotive_field['name'],
       'label' => locomotive_field['label']}
  widget, opts = *field_to_widget(locomotive_field, content_types)
  return nil if widget.nil?

  f['widget'] = widget
  f.merge! opts if opts

  unless locomotive_field['required']
    f['required'] = false
  end
  if locomotive_field['default'] and not locomotive_field['default'].empty?
    f['default'] = locomotive_field['default']
  elsif locomotive_field['name'] == 'published'
    f['default'] = true
  end

  f
end

def to_netlify_collection content_type, content_types
  c = {}
  c['name'] = content_type.slug
  c['label'] = content_type.name
  if content_type.name != content_type.name.singularize
    c['label_singular'] = content_type.name.singularize
  end
  c['description'] = content_type.description
  c['folder'] = "_#{content_type.slug}"

  # Rename news or blog collection to posts if not already
  # present. This is because it is hardcoded in Jekyll anyway and some
  # features are connected to it.
  case content_type.slug
  when 'news', 'blog'
    if content_types.none? {|t| t.slug == 'posts' }
      c['locomotive_name'] = content_type.slug
      c['name'] = 'posts'
      c['folder'] = '_posts'
      c['slug'] = '{{year}}-{{month}}-{{day}}-{{slug}}'
    end
  end

  c['create'] = true
  c['fields'] = content_type.fields.
                  map {|f| to_netlify_field f, content_types }.
                  compact

  unless c['fields'].any? {|f| f['name'] == content_type.order_by }
    field = {
      'name' => unspecialize_name(content_type.order_by),
      'label' => unspecialize_name(content_type.order_by).humanize,
      'widget' => 'number',
      'valueType' => 'int'
    }
    if field['name'] != content_type.order_by
      field['locomotive_name'] = content_type.order_by
    end

    c['fields'] << field
  end

  field_by_widget = c['fields'].group_by {|f| f['widget'] }

  # Rename only markdown field to body
  if field_by_widget['markdown'] and field_by_widget['markdown'].size == 1
    field_by_widget['markdown'].first.merge!({
      'name' => 'body',
      'locomotive_name' => field_by_widget['markdown'].first['name']
    })
  end

  # Rename only date field to date
  if field_by_widget['date'] and field_by_widget['date'].size == 1
    field_by_widget['date'].first.merge!({
      'name' => 'date',
      'locomotive_name' => field_by_widget['date'].first['name']
    })
  end

  # If there is no date, add it.
  if c['fields'].none? {|f| f['name'] == 'date' }
    c['meta'] = [{
      'name' => 'date',
      'label' => 'Created at',
      'widget' => 'date',
      'format' => 'YYYY-MM-DD HH:mm:ss ZZ'
    }]
  end

  c
end

def asset_mapping reload = false
  return @asset_mapping if @asset_mapping and not reload

  @asset_mapping = Hash[
    Dir.new(cms_config['media_folder']).entries.
      reject {|e| e == '.' or e == '..' }.
      map {|e| [e, "/#{cms_config['media_folder']}/#{e}"] }
  ]
end

def asset_mapping!
  asset_mapping true
end

$wagon_asset_semaphore = Mutex.new
def try_to_copy_asset_from_wagon filename
  $wagon_asset_semaphore.synchronize do
    files = Dir["#{WAGON_PUBLIC_DIR}/**/#{filename}"]
    return unless files.size == 1

    src = files.first
    dst = "#{cms_config['media_folder']}/#{unspecialize_name filename}"

    $stderr.puts "cp #{src} #{dst}"
    FileUtils.cp src, dst

    asset_mapping!
  end
end

def local_asset_from remote_asset
  return remote_asset if remote_asset.start_with? '{'

  orig_filename = File.basename remote_asset
  filename = unspecialize_name orig_filename
  uri = URI remote_asset.strip

  # Locomotive CMS for some reason does not give all its assets via
  # API. But they can be found in Wagon and copied here as a last
  # resort.
  if uri.host == ENV['ASSET_HOST'] and not asset_mapping.key?(filename)
    try_to_copy_asset_from_wagon orig_filename
  end

  fail "Unknown asset: #{remote_asset}" if uri.host == ENV['ASSET_HOST'] and
                                           not asset_mapping.key?(filename)

  if asset_mapping.key?(filename)
    asset_mapping[filename]
  else
    remote_asset
  end
end

def field_key_value entry, field
  v = entry.send(field['locomotive_name'] || field['name'])

  case field['widget']
  when 'string', 'text'
    v.strip!
  when 'date'
    if field['format'].include? 'H'
      v = Time.parse v
    else
      v = Date.parse v
    end
  when 'image'
    v = local_asset_from v
  when 'list'
    v.map! do |v_el|
      {field['field']['name'] => v_el}
    end
    v.unshift 'TODO Fix' unless v.empty?
  end

  k = if v == field['default']
        nil
      else
        field['name']
      end

  [k, v]
end

def ensure_order_field document, entry, collection
  return unless collection.key? 'order_by'

  order_value = entry.send collection['order_by']
  order_field = unspecialize_name collection['order_by']
  document[order_field] = order_value
end

def add_implicit_date document, entry, collection
  return if document.key? 'date'

  field = collection['fields'].find {|f| f['name'] == 'date' }

  if field and field.format == 'YYYY-mm-dd'
    document['date'] = Date.parse entry.send field['locomotive_name']
  elsif field
    document['date'] = Time.parse entry.send field['locomotive_name']
  else
    document['date'] = Time.parse entry.created_at
  end
end

def entry_to_document entry, collection
  document = Hash[
    collection['fields'].
      map {|f| field_key_value entry, f }.
      reject {|k, v| k.nil? }
  ]
  ensure_order_field document, entry, collection
  add_implicit_date document, entry, collection

  document
end

def html_with_local_assets html
  doc = Nokogiri::HTML::DocumentFragment.parse html

  doc.css("img[src]").each do |img|
    img['src'] = local_asset_from img['src']
  end

  doc.css("[href]").each do |link|
    link['href'] = local_asset_from link['href']
  end

  doc.to_html
end

def html_to_md html
  Kramdown::Document.
    new(html_with_local_assets(html), input: 'html').
    to_kramdown
end

def delete_document_body_as_md document, collection
  has_md_body = collection['fields'].any? {|f| f['name'] == 'body' and
                                               f['widget'] == 'markdown' }
  return nil unless has_md_body and document['body']

  html_to_md document.delete 'body'
end

def document_filename document, entry, collection
   filename_template = collection['slug'] || '{{slug}}'

   filename = "#{filename_template}.md"
   unless document.key? 'slug'
     filename.gsub! '{{slug}}', (document['slug'] || entry._slug)
   end

   filename.gsub! '{{year}}', document['date'].strftime('%Y')
   filename.gsub! '{{month}}', document['date'].strftime('%m')
   filename.gsub! '{{day}}', document['date'].strftime('%d')

   collection['fields'].each do |f|
     v = document[f['name']] || f['default']
     filename.gsub! "{{#{f['name']}}}", v.to_s
   end

   "#{collection['folder']}/#{filename}"
end

def dump_document document, collection
  body = delete_document_body_as_md document, collection

  res = ''
  res << document.to_yaml
  res << "---\n"
  res << body unless body.nil?

  res
end

def layout? entry
  entry.fullpath.start_with? 'layouts/'
end

def simple_data_from editable_elements
  editable_elements.reduce({}) do |p, el|
    p['editable_elements'] ||= {}
    k = "#{el['block']}/#{el['slug']}"

    case el['type']
    when 'EditableText'
      p['editable_elements'][k] = html_to_md el['content']
    when 'EditableFile'
      p['editable_elements'][k] = local_asset_from el['content']
    when 'EditableControl'
      p['editable_elements'][k] = el['content']
    when 'EditableModel'
      # ignore
    else
      fail "Unexpected editable element of type #{el['type']}"
    end

    p
  end
end

def extract_layout_from_body page_like
  body = page_like['body'].lstrip
  md = /\A\{%-?\s+extends\s+(['"])([^\1]+)\1\s+-?%\}\s*/.match body
  if md and md[2].start_with?('layouts/')
    page_like['layout'] = md[2].split('/', 2).last
    page_like['body'] = body[md.end(0)..-1]
  end
end

def entry_to_layout entry
  layout = {
    'title' => entry.title,
    'listed' => entry.is_layout,
    'body' => entry.template
  }

  layout.merge! simple_data_from entry.editable_elements

  extract_layout_from_body layout

  layout
end

def layout_filename entry
  "#{jekyll_config['layouts_dir']}/#{entry.fullpath.split('/', 2).last}.html"
end

def dump_layout layout
  body = layout.delete 'body'

  res = ''
  unless layout.empty?
    res << layout.to_yaml
    res << "---\n"
  end
  res << body

  res
end

def entry_to_page entry
  page = {'title' => entry.title}
  page['published'] = false if not entry.published
  page['listed'] = entry.listed
  page['position'] = entry.position
  page['body'] = entry.template

  page.merge! simple_data_from entry.editable_elements

  extract_layout_from_body page

  page
end

def page_filename entry
  "#{jekyll_config['source']}/#{entry.fullpath}.html"
end

def dump_page page
  body = page.delete 'body'

  res = ''
  res << page.to_yaml
  res << "---\n"
  res << body

  res
end

$http_get_semaphore = Mutex.new
def http_get resource, &block
  uri = URI resource

  @client ||= {}
  @client[uri.scheme] ||= {}
  $http_get_semaphore.synchronize do
    if not @client[uri.scheme].key?(uri.host) or
       @client[uri.scheme][uri.host].active?
      @client[uri.scheme][uri.host] = Net::HTTP.start(
        uri.host, uri.port, use_ssl: uri.scheme == 'https'
      )
    end
  end

  @client[uri.scheme][uri.host].request(
    Net::HTTP::Get.new(uri), &block
  )
end

def copy_asset asset, file
  dir = File.dirname file
  file = dir + File::SEPARATOR + unspecialize_name(File.basename(file))

  return if File.exist?(file) and
            File.size(file) == asset.raw_size and
            Digest::MD5.file(file) == asset.checksum

  http_get asset.url do |res|
    ensure_dir dir

    $stderr.puts "curl -o #{file} #{asset.url}"
    File.open file, 'w' do |io|
      res.read_body do |chunk|
        io.write chunk
      end
    end
  end
end

def conflict_values_for coll, prop
  val_counts = coll.reduce({}) do |vals, el|
    val = el.send prop
    dir = File.dirname val
    if dir != "." or not val.start_with?(".")
      val = dir + File::SEPARATOR + unspecialize_name(File.basename(val))
    end

    vals[val] ||= 0
    vals[val] += 1
    vals
  end

  val_counts.
    select {|v, c| c > 1 }.
    map {|v, c| v }
end

desc "Migrate everything from site on Locomotive CMS\n" +
     "\n" +
     "The following environment variables are required:\n" +
     "* WAGON: Wagon directory\n" +
     "* DEPLOY_ENV: environment from Wagon deployment configuration\n" +
     "* ASSET_HOST: Locomotive CMS asset host"
multitask migrate: ['migrate:content_entries', 'migrate:theme_assets',
                    'migrate:pages']

namespace "migrate" do
  multitask content_entries: %w[content_types content_assets] do
    site_client.contents.all.each do |t|
      col = cms_config['collections'].find do |c|
        c['locomotive_name'] == t.slug or c['name'] == t.slug
      end

      ensure_dir col['folder']

      page = 1
      while page do
        entries = site_client.contents.send(t.slug).all({}, page: page)

        entries.each do |e|
          d = entry_to_document e, col
          File.write document_filename(d, e, col),
                     dump_document(d, col)
        end

        page = entries._next_page
      end
    end
  end

  task :theme_assets do
    site_client.theme_assets.all.each do |a|
      copy_asset a, "#{jekyll_config['source']}/theme/#{a.local_path}"
    end
  end

  task pages: %[snippets] do
    site_client.pages.all.each do |e|
      if layout? e
        l = entry_to_layout e
        ensure_dir File.dirname layout_filename e
        File.write layout_filename(e), dump_layout(l)
      else
        p = entry_to_page e
        ensure_dir File.dirname page_filename e
        File.write page_filename(e), dump_page(p)
      end
    end
  end

  task :content_types do
    content_types = site_client.contents.all

    config = cms_config!
    orig_config = config.dup
    config['collections'] = content_types.map do |t|
      to_netlify_collection t, content_types
    end

    File.write CMS_CONFIG, config.to_yaml if config != orig_config

    cms_config!
  end

  task :content_assets do
    as = site_client.content_assets.all
    conflicts = conflict_values_for as, :full_filename
    unless conflicts.empty?
      fail "Netlify CMS differentiates uploaded media only based " +
           "on their file name, but there are conflicting names: " +
           conflicts.join(' ')
    end

    site_client.content_assets.all.each do |a|
      copy_asset a, "#{cms_config['media_folder']}/#{a.full_filename}"
    end

    asset_mapping!
  end

  task :snippets do
    ensure_dir jekyll_config['includes_dir']

    site_client.snippets.all.each do |s|
      File.write "#{jekyll_config['includes_dir']}/#{s.slug}.html",
                 s.template
    end
  end
end
