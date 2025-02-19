require 'fileutils'
require 'keyed_archive'
require 'sqlite3'
require 'zlib'
require_relative 'notestore_pb.rb'
require_relative 'AppleCloudKitRecord'
require_relative 'AppleDecrypter.rb'
require_relative 'AppleNotesEmbeddedObject.rb'
require_relative 'AppleNotesEmbeddedDeletedObject.rb'
require_relative 'AppleNotesEmbeddedDrawing.rb'
require_relative 'AppleNotesEmbeddedGallery.rb'
require_relative 'AppleNotesEmbeddedPDF.rb'
require_relative 'AppleNotesEmbeddedPublicObject.rb'
require_relative 'AppleNotesEmbeddedPublicJpeg.rb'
require_relative 'AppleNotesEmbeddedPublicURL.rb'
require_relative 'AppleNotesEmbeddedPublicVCard.rb'
require_relative 'AppleNotesEmbeddedTable.rb'
require_relative 'AppleNoteStore.rb'


##
#
# This class represents an Apple Note.
# It should support both classic Apple Notes and the iCloud version
class AppleNote < AppleCloudKitRecord

  # Constants to reflect the types of styling in an AppleNote
  STYLE_TYPE_DEFAULT = -1
  STYLE_TYPE_TITLE = 0
  STYLE_TYPE_HEADING = 1
  STYLE_TYPE_SUBHEADING = 2
  STYLE_TYPE_MONOSPACED = 4
  STYLE_TYPE_DOTTED_LIST = 100
  STYLE_TYPE_DASHED_LIST = 101
  STYLE_TYPE_NUMBERED_LIST = 102
  STYLE_TYPE_CHECKBOX = 103

  # Constants that reflect the types of font weighting
  FONT_TYPE_DEFAULT = 0
  FONT_TYPE_BOLD = 1
  FONT_TYPE_ITALIC = 2
  FONT_TYPE_BOLD_ITALIC = 3

  attr_accessor :creation_time, 
                :modify_time, 
                :data, 
                :note_id,
                :is_compressed,
                :title,
                :is_password_protected,
                :embedded_objects,
                :plaintext,
                :primary_key,
                :database,
                :decompressed_data,
                :account,
                :backup,
                :crypto_password,
                :cloudkit_creator_record_id,
                :cloudkit_modify_device,
                :folder

  ##
  # Creates a new AppleNote. Expects an Integer +z_pk+, an Integer +znote+ representing the ZICNOTEDATA.ZNOTE field, 
  # a String +ztitle+ representing the ZICCLOUDSYNCINGOBJECT.ZTITLE field, a binary String +zdata+ representing the 
  # ZICNOTEDATA.ZDATA field, an Integer +creation_time+ representing the iOS CoreTime number found in ZICCLOUDSYNCINGOBJECT.ZCREATIONTIME1 field, 
  # an Integer +modify_time+ representing the iOS CoreTime number found in ZICCLOUDSYNCINGOBJECT.ZMODIFICATIONTIME1 field, 
  # an AppleNotesAccount +account+ representing the owning account, an AppleNotesFolder +folder+ representing the holding folder, 
  # and an AppleNoteStore +notestore+ representing the actual NoteStore
  # representing the full backup.
  def initialize(z_pk, znote, ztitle, zdata, creation_time, modify_time, account, folder, notestore)
    super()
    # Initialize some other variables while we're here
    @plaintext = nil
    @decompressed_data = nil
    @encrypted_data = nil
    @crypto_iv = nil
    @crypto_tag = nil
    @crypto_key = nil
    @crypto_salt = nil
    @crypto_iterations = nil
    @crypto_password = nil
    @is_password_protected = false
    @embedded_objects = Array.new()

    # Feed in our arguments
    @primary_key = z_pk
    @note_id = znote
    @title = ztitle
    @compressed_data = zdata
    @creation_time = convert_core_time(creation_time)
    @modify_time = convert_core_time(modify_time)
    @account = account
    @folder = folder
    @notestore = notestore
    @database = @notestore.database
    @backup = @notestore.backup
    @logger = @backup.logger

    # Treat legacy stuff different
    if @notestore.version == AppleNoteStore::IOS_LEGACY_VERSION
      @plaintext = @compressed_data
      @compressed_data = nil
    else
      # Unpack what we can
      @is_compressed = is_gzip(zdata) 
      decompress_data if @is_compressed
      extract_plaintext if @decompressed_data
      replace_embedded_objects if @plaintext
    end
  end

  ##
  # This method returns the appropriate version for the AppleNote. 
  # It does this by checking the AppleNoteStore +@notestore+ and returning that.
  def version
    return @notestore.version if @notestore
    return AppleNoteStore::IOS_VERSION_UNKNOWN
  end

  ##
  # This method takes the +decompressed_data+ as an AppleNotesProto protobuf and 
  # assigned the plaintext from that protobuf into the +plaintext+ variable.
  def extract_plaintext
    if @decompressed_data
      begin
        tmp_note_store_proto = NoteStoreProto.decode(@decompressed_data)
        @plaintext = tmp_note_store_proto.document.note.note_text
      rescue Exception
        puts "Error parsing the protobuf for Note #{@note_id}, have to skip it, see the debug log for more details"
        @logger.error("Error parsing the protobuf for Note #{@note_id}, have to skip it")
        @logger.error("Run the following sqlite query to find the appropriate note data, export the ZDATA column as #{@note_id}.blob.gz, gunzip it, and the resulting #{@note_id}.blob contains your protobuf to check with protoc.")
        @logger.error("\tSELECT ZDATA FROM ZICNOTEDATA WHERE ZNOTE=#{@note_id}")
      end
    end
  end

  ##
  # This method takes the +plaintext+ that is stored and the +decompressed_data+ 
  # as an AppleNotesProto protobuf and loops over all the embedded objects. 
  # For each embedded object it finds, it creates a new AppleNotesEmbeddedObject and 
  # replaces the "obj" placeholder wth the new object's to_s method. This method 
  # creates sub-classes of AppleNotesEmbeddedObject depending on the ZICCLOUDSYNCINGOBJECT.ZTYPEUTI 
  # column.
  def replace_embedded_objects
    if @plaintext
      tmp_note_store_proto = NoteStoreProto.decode(@decompressed_data)
      tmp_note_store_proto.document.note.attribute_run.each do |note_part|

        # Check for something embedded
        if note_part.attachment_info
          tmp_embedded_object = nil
          # If the note was "deleted", the obects will have been deleted, and this will turn up nothing
          @database.execute("SELECT ZICCLOUDSYNCINGOBJECT.Z_PK, ZICCLOUDSYNCINGOBJECT.ZNOTE, " + 
                            "ZICCLOUDSYNCINGOBJECT.ZCREATIONDATE, ZICCLOUDSYNCINGOBJECT.ZMODIFICATIONDATE, " +
                            "ZICCLOUDSYNCINGOBJECT.ZTYPEUTI, ZICCLOUDSYNCINGOBJECT.ZIDENTIFIER " + 
                            "FROM ZICCLOUDSYNCINGOBJECT " +
                            "WHERE ZICCLOUDSYNCINGOBJECT.ZIDENTIFIER=?",
                            note_part.attachment_info.attachment_identifier) do |row|
            @logger.debug("AppleNote: Note #{@note_id} replacing attachment #{row["ZIDENTIFIER"]}")
            case row["ZTYPEUTI"]
              when "public.jpeg", "public.png", "public.tiff"
                tmp_embedded_object = AppleNotesEmbeddedPublicJpeg.new(row["Z_PK"],
                                                                       row["ZIDENTIFIER"],
                                                                       row["ZTYPEUTI"],
                                                                       self,
                                                                       @backup,
                                                                       nil)
              when "public.vcard"
                tmp_embedded_object = AppleNotesEmbeddedPublicVCard.new(row["Z_PK"],
                                                                        row["ZIDENTIFIER"],
                                                                        row["ZTYPEUTI"],
                                                                        self,
                                                                        @backup)
              when "com.adobe.pdf"
                tmp_embedded_object = AppleNotesEmbeddedPDF.new(row["Z_PK"],
                                                                row["ZIDENTIFIER"],
                                                                row["ZTYPEUTI"],
                                                                self,
                                                                @backup)
              when "public.url"
                tmp_embedded_object = AppleNotesEmbeddedPublicURL.new(row["Z_PK"],
                                                                      row["ZIDENTIFIER"],
                                                                      row["ZTYPEUTI"],
                                                                      self)
              when "com.apple.notes.gallery"
                tmp_embedded_object = AppleNotesEmbeddedGallery.new(row["Z_PK"],
                                                                    row["ZIDENTIFIER"],
                                                                    row["ZTYPEUTI"],
                                                                    self,
                                                                    @backup)
              when "com.apple.notes.table"
                tmp_embedded_object = AppleNotesEmbeddedTable.new(row["Z_PK"],
                                                                  row["ZIDENTIFIER"],
                                                                  row["ZTYPEUTI"],
                                                                  self)
              when "com.apple.drawing.2"
                tmp_embedded_object = AppleNotesEmbeddedDrawing.new(row["Z_PK"],
                                                                    row["ZIDENTIFIER"],
                                                                    row["ZTYPEUTI"],
                                                                    self,
                                                                    @backup)
              # Catch any other public.* types that likely represent something stored on disk
              when /public.*/, "com.apple.macbinary-archive"
                tmp_embedded_object = AppleNotesEmbeddedPublicObject.new(row["Z_PK"],
                                                                         row["ZIDENTIFIER"],
                                                                         row["ZTYPEUTI"],
                                                                         self,
                                                                         @backup)

              else
                tmp_embedded_object = AppleNotesEmbeddedObject.new(row["Z_PK"],
                                                                   row["ZIDENTIFIER"],
                                                                   row["ZTYPEUTI"],
                                                                   self)
                puts "#{row["ZTYPEUTI"]} is unrecognized, please submit a bug report to this project's GitHub repo to report this: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/issues"
            end
          end

          # If we still have't created an embedded object, we likely had somthing that was previously deleted
          if !tmp_embedded_object
            tmp_embedded_object = AppleNotesEmbeddedDeletedObject.new(note_part.attachment_info.attachment_identifier,
                                                                      note_part.attachment_info.type_uti,
                                                                      self)
          end

          # Update plaintext to note something else is here
          @plaintext = @plaintext.sub(/\ufffc/, "{#{tmp_embedded_object.to_s}}")
          @embedded_objects.push(tmp_embedded_object)
        end
      end
    end
  end

  ##
  # This class method returns an Array representing the headers needed for an AppleNote CSV export.
  def self.to_csv_headers
    ["Note Primary Key", 
     "Note ID", 
     "Owning Account Name", 
     "Owning Folder Name",
     "Modify By Device", 
     "Cloudkit Creator Record ID", 
     "Title", 
     "Creation Time", 
     "Modify Time", 
     "Note Plaintext", 
     "Is Password protected",
     "Crypto Interations",
     "Crypto Salt (hex)",
     "Crypto Tag (hex)",
     "Crypto Key (hex)",
     "Crypto IV (hex)",
     "Encrypted Data (hex)"]
  end

  ##
  # This method returns an Array representing the AppleNote CSV export row of this object. 
  # Currently that is the +primary_key+, +note_id+, AppleNotesAccount name, AppleNotesFolder name, 
  # +title+, +creation_time+, +modify_time+, +plaintext+, and +is_password_protected+. If there 
  # are cryptographic variables, it also includes the +crypto_salt+, +crypto_tag+, +crypto_key+, 
  # +crypto_iv+, and +encrypted_data+, all as hex, vice binary.
  def to_csv
    [@primary_key, 
     @note_id, 
     @account.name, 
     @folder.name, 
     @cloudkit_last_modified_device, 
     @cloudkit_creator_record_id, 
     @title, 
     @creation_time, 
     @modify_time, 
     @plaintext, 
     @is_password_protected,
     @crypto_iterations,
     get_crypto_salt_hex,
     get_crypto_tag_hex,
     get_crypto_key_hex,
     get_crypto_iv_hex,
     get_encrypted_data_hex]
  end

  ## 
  # This function returns the +crypto_iv+ as hex, if it exists.
  def get_crypto_iv_hex
    return @crypto_iv if ! @crypto_iv
    @crypto_iv.unpack("H*")
  end

  ## 
  # This function returns the +crypto_key+ as hex, if it exists.
  def get_crypto_key_hex
    return @crypto_key if ! @crypto_key
    @crypto_key.unpack("H*")
  end

  ## 
  # This function returns the +crypto_tag+ as hex, if it exists.
  def get_crypto_tag_hex
    return @crypto_tag if ! @crypto_tag
    @crypto_tag.unpack("H*")
  end

  ## 
  # This function returns the +crypto_salt+ as hex, if it exists.
  def get_crypto_salt_hex
    return @crypto_salt if ! @crypto_salt
    @crypto_salt.unpack("H*")
  end

  ## 
  # This function returns the +encrypted_data+ as hex, if it exists.
  def get_encrypted_data_hex
    return @encrypted_data if ! @encrypted_data
    @encrypted_data.unpack("H*")
  end

  ## 
  # This function returns the +plaintext+ for the note.
  def get_note_contents
    return "Error, note not yet decrypted" if @encrypted_data and !@decompressed_data
    return "Error, note not yet decompressed" if !@decompressed_data
    return "Error, note not yet plaintexted" if !@plaintext
    @plaintext
  end

  ##
  # This function checks if specified +data+ is a GZip object by matching the first two bytes.
  def is_gzip(data) 
    /^\x1F\x8B/n.match(data) != nil
  end

  ##
  # This function converts iOS Core Time, specified as an Integer +core_time+, to a Time object.
  def convert_core_time(core_time)
    return Time.at(0) unless core_time
    return Time.at(core_time + 978307200)
  end

  ## 
  # This function decompresses the orginally GZipped data present in +compressed_data+.
  # It stores the result in +decompressed_data+
  def decompress_data
    @decompressed_data = nil

    # Check for GZip magic number
    if is_gzip(@compressed_data)
      zlib_inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
      @decompressed_data = zlib_inflater.inflate(@compressed_data)
    else
      @logger.error("AppleNote: Note #{@note_id} somehow tried to decompress something that was not a GZIP")
    end
  end

  ##
  # This function adds cryptographic settings to the AppleNote. 
  # It expects a +crypto_iv+ as a binary String, a +crypto_tag+ as a binary String, a +crypto_salt+ as a binary String, 
  # the +crypto_iterations+ as an Integer, a +crypto_verifier+ as a binary String, and a +crypto_wrapped_key+ as a binary String.
  # No AppleNote should ahve both a +crypto_verifier+ and a +crypto_wrapped_key+. 
  def add_cryptographic_settings(crypto_iv, crypto_tag, crypto_salt, crypto_iterations, crypto_verifier, crypto_wrapped_key)
    @encrypted_data = @compressed_data # Move what was in compressed by default over to encrypted
    @compressed_data = nil
    @is_password_protected = true
    @crypto_iv = crypto_iv
    @crypto_tag = crypto_tag
    @crypto_salt = crypto_salt
    @crypto_iterations = crypto_iterations
    @crypto_key = crypto_verifier if crypto_verifier
    @crypto_key = crypto_wrapped_key if crypto_wrapped_key
  end

  ##
  # This function ensures all cryptographic variables are set.
  def has_cryptographic_variables?
    return (@is_password_protected and @encrypted_data and @crypto_iv and @crypto_tag and @crypto_salt and @crypto_iterations and @crypto_key)
  end

  ##
  # This function attempts to decrypt the note by providing its cryptographic variables to the AppleDecrypter.
  def decrypt
    return false if !has_cryptographic_variables?

    decrypt_result = @backup.decrypter.decrypt(@crypto_salt, 
                                               @crypto_iterations, 
                                               @crypto_key, 
                                               @crypto_iv, 
                                               @crypto_tag, 
                                               @encrypted_data, 
                                               "Apple Note: #{@note_id}")

    # If we made a decrypt, then kick the result into our normal process to extract everything
    if decrypt_result
      @crypto_password = decrypt_result[:password]
      @compressed_data = decrypt_result[:plaintext]
      decompress_data
      extract_plaintext if @decompressed_data
      replace_embedded_objects if @plaintext
    end

    return (plaintext != false)
  end

  ##
  # This method generates HTML to represent this Note, its 
  # metadata, and its contents, if applicable. It does not generate 
  # full HTML, just enough for this note's card to be displayed.
  def generate_html
    html = "<a id='note_#{@note_id}'><h1>Note #{@note_id}</h1></a>\n"
    html += "<b>Account:</b> #{@account.name} <br />\n"
    html += "<b>Folder:</b> <a href='#folder_#{@folder.primary_key}'>#{@folder.name}</a> <br/>\n"
    html += "<b>Title:</b> #{@title} <br/>\n"
    html += "<b>Created:</b> #{@creation_time} <br/>\n"
    html += "<b>Modified:</b> #{@modify_time} <br />\n"
    #html += "<b>Password:</b> #{@crypto_password} <br />\n" if @crypto_password
    html += "<b>CloudKit Creator:</b> #{@notestore.cloud_kit_participants[@cloudkit_creator_record_id].email} <br />\n" if @cloudkit_creator_record_id and @notestore.cloud_kit_participants[@cloudkit_creator_record_id]
    html += "<b>CloudKit Last Modified User:</b> #{@notestore.cloud_kit_participants[@cloudkit_modifier_record_id].email} <br />\n" if @cloudkit_modifier_record_id and @notestore.cloud_kit_participants[@cloudkit_modifier_record_id]
    html += "<b>CloudKit Last Modified Device:</b> #{@cloudkit_last_modified_device} <br />\n" if @cloudkit_last_modified_device
    #html += "<b>Content:</b>\n"
    html += "<div class='note-content'>\n"

    # Handle the text to insert, only if we have plaintext to run
    if @plaintext
      html += "#{plaintext}" if @notestore.version == AppleNoteStore::IOS_LEGACY_VERSION
      html += generate_html_text if @notestore.version > AppleNoteStore::IOS_VERSION_9
    else
      html += "{Contents not decrypted}" if @encrypted_data
    end
    html += "</div> <!-- Close the 'note-content' div -->\n"
    return html
  end

  def zettel_date
    @creation_time.strftime("%Y%m%d%H%M%S")
  end

  def title
    return @title unless @title.to_s.end_with? "…"
    @title.slice(0, @title.length-1).strip
  end

  def zettel_filename
     "#{zettel_date} #{title}".gsub(/\s/, "\ ").gsub(/\//, '-')
  end

  def generate_html_text
    html = ""

    # Bail out if we don't have anything to decode
    return html if !@decompressed_data

    # Set up variables for the run
    embedded_object_index = 0
    current_index = 0
    current_style = -1

    # Decode the proto
    begin
      tmp_note_store_proto = NoteStoreProto.decode(@decompressed_data)
    rescue Exception
    end

    # Bail out if we don't have anything to decode
    return html if !tmp_note_store_proto
    
    # Create a copy of the text, which is frozen
    note_text = tmp_note_store_proto.document.note.note_text.dup

    # Capture if we're in a checkbox, because they're special
    current_checkbox = nil

    # Iterate over the attribute runs to display stuffs
    tmp_note_store_proto.document.note.attribute_run.each do |note_part|

      # Check for something embedded, if so, don't put in the characters, replace them with the object
      if note_part.attachment_info

        if @embedded_objects[embedded_object_index]
          html += @embedded_objects[embedded_object_index].generate_html# + "\n"
        else
          html += "[Object missing, this is common for deleted notes]"
        end
        embedded_object_index += 1
        current_index += note_part.length

      else # We must have text to parse

        # Deal with styling
        if note_part.paragraph_style

          # Because similar checkboxe carry over past a line break, 
          # need to close it when we hit a different type
          if current_checkbox and note_part.paragraph_style.style_type != STYLE_TYPE_CHECKBOX
            html += "</li></ul>\n"
          end

          # Add in indents, this doesn't work so well
          indents = 0
          while indents < note_part.paragraph_style.indent_amount do
            html += "\t"
            indents += 1
          end

          # Add new style
          case note_part.paragraph_style.style_type
          when STYLE_TYPE_TITLE
            html += "<h1>"
          when STYLE_TYPE_HEADING
            html += "<h2>"
          when STYLE_TYPE_SUBHEADING
            html += "<h3>"
          when STYLE_TYPE_MONOSPACED
            html += "<code>"
          when STYLE_TYPE_NUMBERED_LIST
            html += "<ol><li>"
          when STYLE_TYPE_DOTTED_LIST
            html += "<ul><li>"
          when STYLE_TYPE_DASHED_LIST
            html += "<ul><li>"
          when STYLE_TYPE_CHECKBOX

            # Set the style to apply to the list item
            style = "unchecked"
            style = "checked" if note_part.paragraph_style.checklist.done == 1

            # Open a list if we don't have a current one going
            if !current_checkbox
              html += "<ul class='checklist'><li class='#{style}'>"

            # Or just open a new list element
            elsif current_checkbox != note_part.paragraph_style.checklist.uuid
              html += "</li><li class='#{style}'>"
            end

            # Update our knowledge of the current checkbox
            current_checkbox = note_part.paragraph_style.checklist.uuid
          end
          current_style = note_part.paragraph_style.style_type

        end

        # Add in font stuff
        case note_part.font_weight
        when FONT_TYPE_DEFAULT
          # Do nothing
        when FONT_TYPE_BOLD 
          html += "<b>"
        when FONT_TYPE_ITALIC
          html += "<i>"
        when FONT_TYPE_BOLD_ITALIC
          html += "<b><i>"
        end

        # Add in underlined
        if note_part.underlined == 1
          html += "<u>"
        end

        # Add in strikethrough
        if note_part.strikethrough == 1
          html += "<del>"
        end

        # Add in the slice of text represented by this run
        slice_to_add = note_text.slice(current_index, note_part.length)

        # Apple seems to be making Emojis and some other characters two characters
        # this breaks stuff. This is a really hacky solution.
        double_characters = 0
        slice_to_add.each_codepoint do |codepoint|
          double_characters += 1 if codepoint > 65535
        end

        if double_characters > 0
          slice_to_add = note_text.slice(current_index, note_part.length - double_characters)
        end
        
        # Deal with newlines
        if current_style == STYLE_TYPE_NUMBERED_LIST or current_style == STYLE_TYPE_DOTTED_LIST or current_style == STYLE_TYPE_DASHED_LIST
          slice_to_add = slice_to_add.split("\n").join("</li><li>")
        elsif current_style == STYLE_TYPE_CHECKBOX
          slice_to_add.gsub!("\n","")
        end

        html += slice_to_add

        # Increment our counter to be sure we don't loop infinitely
        current_index += (note_part.length - double_characters)

        # Close strikethrough
        if note_part.strikethrough == 1
          html += "</del>"
        end

        # Close underlined
        if note_part.underlined == 1
          html += "</u>"
        end

        # Close font stuff
        case note_part.font_weight
        when FONT_TYPE_DEFAULT
          # Do nothing
        when FONT_TYPE_BOLD
          html += "</b>"
        when FONT_TYPE_ITALIC
          html += "</i>"
        when FONT_TYPE_BOLD_ITALIC
          html += "</i></b>"
        end

        # Close any remaining styles
        case current_style
        when STYLE_TYPE_TITLE
          html += "</h1>"
        when STYLE_TYPE_HEADING
          html += "</h2>"
        when STYLE_TYPE_SUBHEADING
          html += "</h3>"
        when STYLE_TYPE_MONOSPACED
          html += "</code>"
        when STYLE_TYPE_NUMBERED_LIST
          html += "</li></ol>"
        when STYLE_TYPE_DOTTED_LIST
          html += "</li></ul>"
        when STYLE_TYPE_DASHED_LIST
          html += "</li></ul>"
        end

        if slice_to_add[-1] == "\n"
          #html += "\n";
        end

      end


    end

    html.gsub!('</h1><h1>','')
    html.gsub!('</h2><h2>','')
    html.gsub!('</h3><h3>','')
    html.gsub!('</code><code>','')
    html.gsub!('</del><del>','')
    html.gsub!('</b><b>','')
    html.gsub!('</i><i>','')
    html.gsub!('</u><u>','')
    html.gsub!(/<h1>\s*<\/h1>/,'') # Remove empty titles
    html.gsub!(/\n<\/h1>/,'</h1>') # Remove extra line breaks in front of h1
    html.gsub!(/\n<\/h2>/,'</h2>') # Remove extra line breaks in front of h2
    html.gsub!(/\n<\/h3>/,'</h3>') # Remove extra line breaks in front of h3

    # Return what we've built
    return html
  end

  def generate_markdown
    meta = <<~META
      id: #{@note_id}
      account: #{@account.name}
      folder:
        key: #{@folder.primary_key}
        name: #{@folder.name}
      title: #{title}
      created_at: #{@creation_time}
      last_modified: #{@modify_time}
      password: #{@crypto_password}
      created_by: #{@notestore.cloud_kit_participants[@cloudkit_creator_record_id].email if @notestore.cloud_kit_participants[@cloudkit_creator_record_id]}
      last_modified_by: #{@notestore.cloud_kit_participants[@cloudkit_modifier_record_id].email if @notestore.cloud_kit_participants[@cloudkit_modifier_record_id]}
      last_modified_on: #{@cloudkit_last_modified_device}
    META
    
    content = ""
    # Handle the text to insert, only if we have plaintext to run
    if @plaintext
      content += "#{plaintext}" if @notestore.version == AppleNoteStore::IOS_LEGACY_VERSION
      content += generate_markdown_text if @notestore.version > AppleNoteStore::IOS_VERSION_9
    else
      content += "%%Contents not decrypted%%" if @encrypted_data
    end
    return <<~CONTENT
    ---
    #{meta}---
    #{content}

    CONTENT
  end

  def generate_markdown_text
    html = ""

    # Bail out if we don't have anything to decode
    return html if !@decompressed_data

    # Set up variables for the run
    embedded_object_index = 0
    current_index = 0
    current_style = -1

    # Decode the proto
    begin
      tmp_note_store_proto = NoteStoreProto.decode(@decompressed_data)
    rescue Exception
    end

    # Bail out if we don't have anything to decode
    return html if !tmp_note_store_proto
    
    # Create a copy of the text, which is frozen
    note_text = tmp_note_store_proto.document.note.note_text.dup

    # Capture if we're in a checkbox, because they're special
    current_checkbox = nil

    # Iterate over the attribute runs to display stuffs
    tmp_note_store_proto.document.note.attribute_run.each do |note_part|

      # Check for something embedded, if so, don't put in the characters, replace them with the object
      if note_part.attachment_info

        if @embedded_objects[embedded_object_index]
          html += @embedded_objects[embedded_object_index].to_markdown
        else
          html += "\n%%Object missing, this is common for deleted notes%%\n"
        end
        embedded_object_index += 1
        current_index += note_part.length

      else # We must have text to parse

        # Deal with styling
        if note_part.paragraph_style

          # Because similar checkboxe carry over past a line break, 
          # need to close it when we hit a different type
          if current_checkbox and note_part.paragraph_style.style_type != STYLE_TYPE_CHECKBOX
            html += "\n"
          end

          # Add in indents, this doesn't work so well
          indents = 0
          while indents < note_part.paragraph_style.indent_amount do
            html += "  "
            indents += 1
          end

          # Add new style
          case note_part.paragraph_style.style_type
          when STYLE_TYPE_TITLE
            html += "# "
          when STYLE_TYPE_HEADING
            html += "## "
          when STYLE_TYPE_SUBHEADING
            html += "### "
          when STYLE_TYPE_MONOSPACED
            html += "`"
          when STYLE_TYPE_NUMBERED_LIST
            html += ""
          when STYLE_TYPE_DOTTED_LIST
            html += "* "
          when STYLE_TYPE_DASHED_LIST
            html += "- "
          when STYLE_TYPE_CHECKBOX
            # Set the style to apply to the list item
            style = " "
            style = "x" if note_part.paragraph_style.checklist.done == 1

            html += "\n- [#{style}] "

            # Update our knowledge of the current checkbox
            current_checkbox = note_part.paragraph_style.checklist.uuid
          end
          current_style = note_part.paragraph_style.style_type

        end

        # Add in font stuff
        case note_part.font_weight
        when FONT_TYPE_DEFAULT
          # Do nothing
        when FONT_TYPE_BOLD 
          html += "**"
        when FONT_TYPE_ITALIC
          html += "_"
        when FONT_TYPE_BOLD_ITALIC
          html += "**_"
        end

        # Add in underlined
        if note_part.underlined == 1
          html += "_"
        end

        # Add in strikethrough
        if note_part.strikethrough == 1
          html += "~~"
        end

        # Add in the slice of text represented by this run
        slice_to_add = note_text.slice(current_index, note_part.length)

        # Apple seems to be making Emojis and some other characters two characters
        # this breaks stuff. This is a really hacky solution.
        double_characters = 0
        slice_to_add.each_codepoint do |codepoint|
          double_characters += 1 if codepoint > 65535
        end

        if double_characters > 0
          slice_to_add = note_text.slice(current_index, note_part.length - double_characters)
        end
        
        # # Deal with newlines
        # case current_style
        # when STYLE_TYPE_DOTTED_LIST
        #   slice_to_add = slice_to_add.split("\n").map{|e| ""}.join("\n")
        # when STYLE_TYPE_DASHED_LIST
        #   slice_to_add = slice_to_add.split("\n").map{|| }.join("\n")
        # when STYLE_TYPE_NUMBERED_LIST 
        #   slice_to_add = slice_to_add.split("\n").map{|| }.join("\n")
        # end

        html += slice_to_add

        # Increment our counter to be sure we don't loop infinitely
        current_index += (note_part.length - double_characters)

        # Close strikethrough
        if note_part.strikethrough == 1
          html += "~~"
        end

        # Close underlined
        if note_part.underlined == 1
          html += "_"
        end

        # Close font stuff
        case note_part.font_weight
        when FONT_TYPE_DEFAULT
          # Do nothing
        when FONT_TYPE_BOLD
          html += "**"
        when FONT_TYPE_ITALIC
          html += "_"
        when FONT_TYPE_BOLD_ITALIC
          html += "_**"
        end

        # Close any remaining styles
        case current_style
        when STYLE_TYPE_TITLE
          html += "\n\n"
        when STYLE_TYPE_HEADING
          html += "\n"
        when STYLE_TYPE_SUBHEADING
          html += "\n"
        when STYLE_TYPE_MONOSPACED
          html += "`"
        when STYLE_TYPE_NUMBERED_LIST
          html += "\n"
        when STYLE_TYPE_DOTTED_LIST
          html += "\n"
        when STYLE_TYPE_DASHED_LIST
          html += "\n"
        end

        if slice_to_add[-1] == "\n"
          #html += "\n";
        end

      end

    end

    # html.gsub!('</h1><h1>','')
    # html.gsub!('</h2><h2>','')
    # html.gsub!('</h3><h3>','')
    # html.gsub!('</code><code>','')
    # html.gsub!('</del><del>','')
    # html.gsub!('</b><b>','')
    # html.gsub!('</i><i>','')
    # html.gsub!('</u><u>','')
    # html.gsub!(/<h1>\s*<\/h1>/,'') # Remove empty titles
    # html.gsub!(/\n<\/h1>/,'</h1>') # Remove extra line breaks in front of h1
    # html.gsub!(/\n<\/h2>/,'</h2>') # Remove extra line breaks in front of h2
    # html.gsub!(/\n<\/h3>/,'</h3>') # Remove extra line breaks in front of h3

    # Return what we've built
    return html
  end


end
