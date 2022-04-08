# frozen_string_literal: true

# This file is part of the ruby-dbus project
# Copyright (C) 2022 Martin Vidner
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License, version 2.1 as published by the Free Software Foundation.
# See the file "COPYING" for the exact licensing terms.

module DBus
  # FIXME: in general, when an API gives me, a user, a choice,
  # remember to make it easy for the case of:
  # "I don't CARE, I don't WANT to care, WHY should I care?"

  # Exact/explicit representation of D-Bus data types:
  #
  # - {Boolean}
  # - {Byte}, {Int16}, {Int32}, {Int64}, {UInt16}, {UInt32}, {UInt64}
  # - {Double}
  # - {String}, {ObjectPath}, {Signature}
  # - {Array}, {DictEntry}, {Struct}
  # - {UnixFD}
  # - {Variant}
  #
  # The common base type is {Base}.
  #
  # There are other intermediate classes in the inheritance hierarchy, using
  # the names the specification uses, but they are an implementation detail:
  #
  # - A value is either {Basic} or a {Container}.
  # - Basic values are either {Fixed}-size or {StringLike}.
  module Data
    # Given a plain Ruby *value* and wanting a D-Bus *type*,
    # construct an appropriate {Data::Base} instance.
    #
    # @param type [SingleCompleteType,Type]
    # @param value [::Object]
    # @return [Data::Base]
    # @raise TypeError
    def make_typed(type, value)
      type = DBus.type(type) unless type.is_a?(Type)
      data_class = Data::BY_TYPE_CODE[type.sigtype]
      # not nil because DBus.type validates

      data_class.from_typed(value, member_types: type.members)
    end
    module_function :make_typed

    # The base class for explicitly typed values.
    #
    # A value is either {Basic} or a {Container}.
    # {Basic} values are either {Fixed}-size or {StringLike}.
    class Base
      # @!method self.basic?
      # @return [Boolean]

      # @!method self.fixed?
      # @return [Boolean]

      # @return appropriately-typed, valid value
      attr_reader :value

      # @!method type
      # @abstract
      # Note that for Variants type=="v",
      # for the specific see {Variant#member_type}
      # @return [Type] the exact type of this value

      # Child classes must validate *value*.
      def initialize(value)
        @value = value
      end

      def ==(other)
        @value == if other.is_a?(Base)
                    other.value
                  else
                    other
                  end
      end

      # Hash key equality
      # See https://ruby-doc.org/core-3.0.0/Object.html#method-i-eql-3F
      alias eql? ==
    end

    # A value that is not a {Container}.
    class Basic < Base
      def self.basic?
        true
      end

      # @return [Type]
      def self.type
        # memoize
        @type ||= Type.new(type_code).freeze
      end

      def type
        # The basic types can do this, unlike the containers
        self.class.type
      end

      # @param value [::Object]
      # @param member_types [::Array<Type>] (ignored, will be empty)
      # @return [Basic]
      def self.from_typed(value, member_types:) # rubocop:disable Lint/UnusedMethodArgument
        # assert member_types.empty?
        new(value)
      end
    end

    # A value that has a fixed size (unlike {StringLike}).
    class Fixed < Basic
      def self.fixed?
        true
      end

      # most Fixed types are valid
      # whatever bits from the wire are used to initialize them
      # @param mode [:plain,:exact]
      def self.from_raw(value, mode:)
        return value if mode == :plain

        new(value)
      end

      # @param endianness [:little,:big]
      def marshall(endianness)
        [value].pack(self.class.format[endianness])
      end
    end

    # {DBus::Data::String}, {DBus::Data::ObjectPath}, or {DBus::Data::Signature}.
    class StringLike < Basic
      def self.fixed?
        false
      end

      def initialize(value)
        if value.is_a?(self.class)
          value = value.value
        else
          self.class.validate_raw!(value)
        end

        super(value)
      end
    end

    # Contains one or more other values.
    class Container < Base
      def self.basic?
        false
      end

      def self.fixed?
        false
      end
    end

    # Format strings for String#unpack, both little- and big-endian.
    Format = ::Struct.new(:little, :big)

    # Represents integers
    class Int < Fixed
      # @!method self.range
      # @return [Range] the full range of allowed values

      # @param value [::Integer,DBus::Data::Int]
      # @raise RangeError
      def initialize(value)
        value = value.value if value.is_a?(self.class)
        r = self.class.range
        raise RangeError, "#{value.inspect} is not a member of #{r}" unless r.member?(value)

        super(value)
      end
    end

    # Byte.
    #
    # TODO: a specialized ByteArray for `ay` may be useful,
    # to save memory and for natural handling
    class Byte < Int
      def self.type_code
        "y"
      end

      def self.alignment
        1
      end
      FORMAT = Format.new("C", "C")
      def self.format
        FORMAT
      end

      def self.range
        (0..255)
      end
    end

    # Boolean: encoded as a {UInt32} but only 0 and 1 are valid.
    class Boolean < Fixed
      def self.type_code
        "b"
      end

      def self.alignment
        4
      end
      FORMAT = Format.new("L<", "L>")
      def self.format
        FORMAT
      end

      def self.validate_raw!(value)
        return if [0, 1].member?(value)

        raise InvalidPacketException, "BOOLEAN must be 0 or 1, found #{value}"
      end

      def self.from_raw(value, mode:)
        validate_raw!(value)

        value = value == 1
        return value if mode == :plain

        new(value)
      end

      # Accept any *value*, store its Ruby truth value
      # (excepting another instance of this class, where use its {#value}).
      #
      # So new(0).value is true.
      # @param value [::Object,DBus::Data::Boolean]
      def initialize(value)
        value = value.value if value.is_a?(self.class)
        super(value ? true : false)
      end

      # @param endianness [:little,:big]
      def marshall(endianness)
        int = value ? 1 : 0
        [int].pack(UInt32.format[endianness])
      end
    end

    # Signed 16 bit integer.
    class Int16 < Int
      def self.type_code
        "n"
      end

      def self.alignment
        2
      end

      FORMAT = Format.new("s<", "s>")
      def self.format
        FORMAT
      end

      def self.range
        (-32_768..32_767)
      end
    end

    # Unsigned 16 bit integer.
    class UInt16 < Int
      def self.type_code
        "q"
      end

      def self.alignment
        2
      end

      FORMAT = Format.new("S<", "S>")
      def self.format
        FORMAT
      end

      def self.range
        (0..65_535)
      end
    end

    # Signed 32 bit integer.
    class Int32 < Int
      def self.type_code
        "i"
      end

      def self.alignment
        4
      end

      FORMAT = Format.new("l<", "l>")
      def self.format
        FORMAT
      end

      def self.range
        (-2_147_483_648..2_147_483_647)
      end
    end

    # Unsigned 32 bit integer.
    class UInt32 < Int
      def self.type_code
        "u"
      end

      def self.alignment
        4
      end

      FORMAT = Format.new("L<", "L>")
      def self.format
        FORMAT
      end

      def self.range
        (0..4_294_967_295)
      end
    end

    # Unix file descriptor, not implemented yet.
    class UnixFD < UInt32
      def self.type_code
        "h"
      end
    end

    # Signed 64 bit integer.
    class Int64 < Int
      def self.type_code
        "x"
      end

      def self.alignment
        8
      end

      FORMAT = Format.new("q<", "q>")
      def self.format
        FORMAT
      end

      def self.range
        (-9_223_372_036_854_775_808..9_223_372_036_854_775_807)
      end
    end

    # Unsigned 64 bit integer.
    class UInt64 < Int
      def self.type_code
        "t"
      end

      def self.alignment
        8
      end

      FORMAT = Format.new("Q<", "Q>")
      def self.format
        FORMAT
      end

      def self.range
        (0..18_446_744_073_709_551_615)
      end
    end

    # Double-precision floating point number.
    class Double < Fixed
      def self.type_code
        "d"
      end

      def self.alignment
        8
      end

      FORMAT = Format.new("E", "G")
      def self.format
        FORMAT
      end

      # @param value [#to_f,DBus::Data::Double]
      # @raise TypeError,ArgumentError
      def initialize(value)
        value = value.value if value.is_a?(self.class)
        value = Kernel.Float(value)
        super(value)
      end
    end

    # UTF-8 encoded string.
    class String < StringLike
      def self.type_code
        "s"
      end

      def self.alignment
        4
      end

      def self.size_class
        UInt32
      end

      def self.validate_raw!(value)
        value.each_codepoint do |cp|
          raise InvalidPacketException, "Invalid string, contains NUL" if cp.zero?
        end
      rescue ArgumentError
        raise InvalidPacketException, "Invalid string, not in UTF-8"
      end

      def self.from_raw(value, mode:)
        value.force_encoding(Encoding::UTF_8)
        if mode == :plain
          validate_raw!(value)
          return value
        end

        new(value)
      end
    end

    # See also {DBus::ObjectPath}
    class ObjectPath < StringLike
      def self.type_code
        "o"
      end

      def self.alignment
        4
      end

      def self.size_class
        UInt32
      end

      # @raise InvalidPacketException
      def self.validate_raw!(value)
        DBus::ObjectPath.new(value)
      rescue DBus::Error => e
        raise InvalidPacketException, e.message
      end

      def self.from_raw(value, mode:)
        if mode == :plain
          validate_raw!(value)
          return value
        end

        new(value)
      end
    end

    # Signature string, zero or more single complete types.
    # See also {DBus::Type}
    class Signature < StringLike
      def self.type_code
        "g"
      end

      def self.alignment
        1
      end

      def self.size_class
        Byte
      end

      # @return [Array<Type>]
      def self.validate_raw!(value)
        DBus.types(value)
      rescue Type::SignatureException => e
        raise InvalidPacketException, "Invalid signature: #{e.message}"
      end

      def self.from_raw(value, mode:)
        if mode == :plain
          _types = validate_raw!(value)
          return value
        end

        new(value)
      end
    end

    # An Array, or a Dictionary (Hash).
    class Array < Container
      def self.type_code
        "a"
      end

      def self.alignment
        4
      end

      # @return [Type]
      attr_reader :member_type

      def type
        return @type if @type

        # TODO: reconstructing the type is cumbersome; have #initialize take *type* instead?
        # TODO: or rather add Type::Array[t]
        @type = Type.new("a")
        @type << member_type
        @type
      end

      # TODO: check that Hash keys are basic types
      # @param mode [:plain,:exact]
      # @param member_type [Type]
      # @param hash [Boolean] are we unmarshalling an ARRAY of DICT_ENTRY
      # @return [Data::Array]
      def self.from_items(value, mode:, member_type:, hash: false)
        value = Hash[value] if hash
        return value if mode == :plain

        new(value, member_type: member_type)
      end

      # @param value [::Object]
      # @param member_types [::Array<Type>]
      # @return [Data::Array]
      def self.from_typed(value, member_types:)
        # TODO: validation
        member_type = member_types.first

        # TODO: Dict??
        items = value.map do |i|
          Data.make_typed(member_type, i)
        end

        new(items, member_type: member_type) # initialize(::Array<Data::Base>)
      end

      # FIXME: should Data::Array be mutable?
      # if it is, is its type mutable too?

      # TODO: specify type or guess type?
      # Data is the exact type, so its constructor should be exact
      # and guesswork should be clearly labeled
      # @param member_type [SingleCompleteType,Type]
      def initialize(value, member_type:)
        member_type = DBus.type(member_type) unless member_type.is_a?(Type)
        # TODO: copy from another Data::Array
        @member_type = member_type
        @type = nil
        super(value)
      end
    end

    # A fixed size, heterogenerous tuple.
    #
    # (The item count is fixed, not the byte size.)
    class Struct < Container
      def self.type_code
        "r"
      end

      def self.alignment
        8
      end

      # @return [::Array<Type>]
      attr_reader :member_types

      def type
        return @type if @type

        # TODO: reconstructing the type is cumbersome; have #initialize take *type* instead?
        # TODO: or rather add Type::Struct[t1, t2, ...]
        @type = Type.new(self.class.type_code, abstract: true)
        @member_types.each do |member_type|
          @type << member_type
        end
        @type
      end

      # @param value [::Array]
      def self.from_items(value, mode:, member_types:)
        value.freeze
        return value if mode == :plain

        new(value, member_types: member_types)
      end

      # @param value [::Object] (#size, #each)
      # @param member_types [::Array<Type>]
      # @return [Struct]
      def self.from_typed(value, member_types:)
        # TODO: validation
        raise unless value.size == member_types.size

        items = member_types.zip(value).map do |item_type, item|
          Data.make_typed(item_type, item)
        end

        new(items, member_types: member_types) # initialize(::Array<Data::Base>)
      end

      def initialize(value, member_types:)
        @member_types = member_types
        @type = nil
        super(value)
      end
    end

    # A generic type
    class Variant < Container
      def self.type_code
        "v"
      end

      def self.alignment
        1
      end

      # @param member_type [Type]
      def self.from_items(value, mode:, member_type:)
        return value if mode == :plain

        new(value, member_type: member_type)
      end

      # @param value [::Object]
      # @param member_types [::Array<Type>]
      # @return [Variant]
      def self.from_typed(value, member_types:) # rubocop:disable Lint/UnusedMethodArgument
        # assert member_types.empty?

        # decide on type of value
        new(value, member_type: nil)
      end

      # @return [Type]
      def self.type
        # memoize
        @type ||= Type.new(type_code).freeze
      end

      # Note that for Variants type.to_s=="v",
      # for the specific see {Variant#member_type}
      # @return [Type] the exact type of this value
      def type
        self.class.type
      end

      # @return [Type]
      attr_reader :member_type

      def self.guess_type(value)
        sct, = PacketMarshaller.make_variant(value)
        DBus.type(sct)
      end

      # @param member_type [Type,nil]
      def initialize(value, member_type:)
        # TODO: validate that the given *member_type* matches *value*
        if value.is_a?(self.class)
          # Copy the contained value instead of boxing it more
          # TODO: except perhaps for round-tripping in exact mode?
          @member_type = value.member_type
          value = value.value
        else
          @member_type = member_type || self.class.guess_type(value)
        end
        super(value)
      end
    end

    # Dictionary/Hash entry.
    # TODO: shouldn't instantiate?
    class DictEntry < Container
      def self.type_code
        "e"
      end

      def self.alignment
        8
      end

      # @return [::Array<Type>]
      attr_reader :member_types

      def type
        return @type if @type

        # TODO: reconstructing the type is cumbersome; have #initialize take *type* instead?
        @type = Type.new(self.class.type_code, abstract: true)
        @member_types.each do |member_type|
          @type << member_type
        end
        @type
      end

      # @param value [::Array]
      def self.from_items(value, mode:, member_types:) # rubocop:disable Lint/UnusedMethodArgument
        value.freeze
        # DictEntry ignores the :exact mode
        value
      end

      # @param value [::Object] (#size, #each)
      # @param member_types [::Array<Type>]
      # @return [DictEntry]
      def self.from_typed(value, member_types:)
        # assert member_types.size == 2
        # TODO: duplicated from Struct. Inherit/delegate?
        # TODO: validation
        raise unless value.size == member_types.size

        items = member_types.zip(value).map do |item_type, item|
          Data.make_typed(item_type, item)
        end

        new(items, member_types: member_types) # initialize(::Array<Data::Base>)
      end

      def initialize(value, member_types:)
        @member_types = member_types
        @type = nil
        super(value)
      end
    end

    consts = constants.map { |c_sym| const_get(c_sym) }
    classes = consts.find_all { |c| c.respond_to?(:type_code) }
    by_type_code = classes.map { |cl| [cl.type_code, cl] }.to_h

    # { "b" => Data::Boolean, "s" => Data::String, ...}
    BY_TYPE_CODE = by_type_code
  end
end
