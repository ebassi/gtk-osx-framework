#
# Helper functions for the framework creation scripts.
#
# Copyright (C) 2007, 2008 Imendio AB
#

if [ "x$framework_helpers_inited" = x ]; then
    framework_helpers_inited=yes
    trap do_abort SIGHUP SIGINT SIGTERM SIGQUIT SIGILL SIGTRAP SIGABRT SIGBUS 
fi

print_help()
{
    do_exit 1 "Usage: `basename $0` <prefix>"
}

fix_library_prefixes()
{
    echo "Updating library names..."

    directory=$1
    from="$old_prefix"/lib
    to="$new_prefix"

    pushd . >/dev/null
    cd $directory

    libs=`ls *{so,dylib} 2>/dev/null`
    for i in $libs; do
	fixlibs=`otool -L $i 2>/dev/null | fgrep compatibility | cut -d\( -f1 | grep "$from"`

	for j in $fixlibs; do
	    new=`echo $j | sed -e s@$from@$to@`
	    install_name_tool -change "$j" "$new" "$i" || do_exit 1
	done
    done

    popd >/dev/null
}

do_exit()
{
    echo -ne "\033]0;\007"

    if [ "x$2" != x ]; then
        echo $2
    else
        echo "Exiting."
    fi

    exit $1
}

do_abort()
{
    echo -ne "\033]0;\007"
    echo "Aborting."
    exit 1
}

init()
{
    if [ x"$2" = x ]; then
	print_help
	do_exit 1
    fi

    if [ ! -d "$2" ]; then
	do_exit 1 "The directory $2 does not exist"
    fi

    if [ ! -x "$2" ]; then
	do_exit 1 "The framework in $2 is not accessible"
    fi

    # Drop any trailing slash.
    old_prefix=`dirname "$2"`/`basename "$2"`
    old_prefix=`echo $old_prefix | sed -e "s@//@/@"`

    main_library="$old_prefix/lib/$3"

    if [ ! -x "$main_library" ]; then
	do_exit 1 "Required library $main_library does not exist."
    fi

    framework_name="$1"

    framework="`pwd`/$framework_name.framework"
    new_prefix="$framework/Libraries"

    if [ -x $framework ]; then
	do_exit 1 "Framework directory already exists."
    fi

    echo "Creating $framework_name.framework skeleton..."
    echo -ne "\033]0;Creating $framework_name.framework\007"

    mkdir -p "$framework"
    mkdir "$framework"/Libraries
    mkdir "$framework"/Resources
    mkdir "$framework"/Headers

    cp data/Info-$framework_name.plist "$framework"/Resources/Info.plist || exit 1
}

copy_main_library()
{
    echo "Copying main library..."

    cp $main_library "$framework"/Libraries/
    newid=`echo "$main_library" | sed -e "s@$old_prefix/lib@$new_prefix@"`
    install_name_tool -id "$newid" "$newid" || do_exit 1
}

symlink_framework_library()
{
    # This symlink is used to build any autotool based modules. Since
    # the install name points to the framework library, the
    # dependencies will end up right, but libtool needs a name on the
    # form "libfoo.dylib". The pkg-config file points to this
    # directory and library.
    mkdir -p "$framework"/Resources/dev/lib
    ln -s "$framework"/$framework_name "$framework"/Resources/dev/lib/lib$framework_name.dylib || do_exit 1
}

copy_single_main_library()
{
    echo "Copying single main library..."

    cp $main_library "$framework"/$framework_name
    newid="$framework"/$framework_name
    install_name_tool -id "$newid" "$newid" || do_exit 1

    symlink_framework_library
}

resolve_dependencies()
{
    echo "Resolving dependencies ..."

    files_left=true
    nfiles=0

    while $files_left; do
	libs1=`find $framework_name.framework/Resources/lib -name "*.dylib" -o -name "*.so" 2>/dev/null`
	libs2=`find $framework_name.framework/Libraries -name "*.dylib" -o -name "*.so" 2>/dev/null`
	deplibs=`otool -L $libs1 $libs2 2>/dev/null | fgrep compatibility | cut -d\( -f1 | grep "$old_prefix"/lib | grep -v "$main_library" | sort | uniq`

	# Copy library and correct ID
	for j in $deplibs; do
	    j=`echo $j | sed -e "s@$old_prefix/lib@@"`
	    j=`echo $j | sed -e "s@^/@@"`

	    cp -f "$old_prefix"/lib/$j "$framework"/Libraries

	    libname=`echo $j | sed -e "s@[\.-0123456789].*@@"`
	    newid=`otool -L "$framework"/Libraries/$j 2>/dev/null | fgrep compatibility | grep $libname | cut -d\( -f1`
	    newid=`echo $newid | sed -e "s@$old_prefix/lib@$new_prefix@"`

	    install_name_tool -id "$newid" "$framework"/Libraries/"$j" || do_exit 1
	done

	nnfiles=`ls "$framework"/Libraries/*dylib 2>/dev/null| wc -l`;
	if [ $nnfiles = $nfiles ]; then
	    files_left=false
	else
	    nfiles=$nnfiles
	fi
    done
}

copy_pc_files()
{
    echo "Creating and copying pkg-config files ..."

    escaped_framework=`echo "$framework" | sed -e 's@\/@\\\/@g' -e 's@\.@\\\.@g'`

    if [ "x$2" != x ]; then
        requires='-e "s/\(^Requires:\).*/\1 $2/"'
    fi

    mkdir -p "$framework"/Resources/dev/lib/pkgconfig

    for pc in $1; do
    cat "$old_prefix"/lib/pkgconfig/$pc | sed \
        -e "s/\(^prefix=\).*/\1$escaped_framework\/Resources/" \
        -e "s/\(^Requires.private:\).*/\1/" \
        -e "s/\(^Libs:\).*/\1 -L$escaped_framework\/Resources\/dev\/lib -l$framework_name/" \
        -e "s/\(^Cflags:\).*/\1 -I$escaped_framework\/Headers/" > "$framework"/Resources/dev/lib/pkgconfig/$pc
    done
}

build_framework_library()
{
    echo "Building main $framework_name library..."

    pushd . >/dev/null
    cd src

    MACOSX_DEPLOYMENT_TARGET=10.4 make $framework_name >/dev/null || do_exit 1
    mv $framework_name "$framework"/$framework_name || do_exit 1

    popd >/dev/null

    symlink_framework_library
}

copy_headers()
{
    echo "Copying header files..."

    while(test "x$1" != x); do
        dir=$1
        shift 1

        if [ "x$1" == x ]; then
            do_exit 1 "Wrong number of arguments, need pairs of from/to paths"
        fi

        tail=$1
        if [ x$tail == x. ]; then
            tail=
        fi

        shift 1

        cp -R "$old_prefix/$dir/$tail" "$framework/Headers/$tail"
    done
}

copy_dev_executables()
{
    echo "Copying executables..."

    mkdir -p "$framework"/Resources/dev/bin

    for i in $*; do
        full_path="$old_prefix"/bin/"$i"
        cp "$full_path" "$framework"/Resources/dev/bin

        if [ "x`file "$full_path" | grep Mach-O\ executable`" != x ]; then
            fixlibs=`otool -L "$full_path" 2>/dev/null | fgrep compatibility | cut -d\( -f1 | grep "$old_prefix"/lib`
	    for j in $fixlibs; do
                # Also change any references to the renamed gdk-pixbuf library.
	        new=`echo $j | sed -e s@$old_prefix/lib@$new_prefix@ -e s@libgdk_pixbuf-@libgdk-pixbuf-@`
	        install_name_tool -change "$j" "$new" "$framework"/Resources/dev/bin/"$i" || do_exit 1
	    done
        fi
    done
}

copy_aclocal_macros()
{
    echo "Copying aclocal macros..."

    dest="$framework"/Resources/dev/share/aclocal
    mkdir -p "$dest"

    for i in $*; do
        cp "$old_prefix"/share/aclocal/"$i" "$dest"
    done
}

update_dev_file()
{
    file=$1

    if [ ! -f "$file" ]; then
        return
    fi

    sed -e "s,$old_prefix,$framework/Resources/dev," "$file" > "$file.tmp" || do_exit 1
    mv "$file.tmp" "$file"

    if echo "$file" | grep "/dev/bin/" >/dev/null; then
        chmod +x $file
    fi
}
