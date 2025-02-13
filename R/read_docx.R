#' @export
#' @title open a connection to a 'Word' file
#' @description read and import a docx file as an R object
#' representing the document.
#' @param path path to the docx file to use as base document.
#' @param x an rdocx object
#' @examples
#' # create an rdocx object with default template ---
#' read_docx()
#'
#' @importFrom xml2 read_xml xml_length xml_find_first as_list
read_docx <- function( path = NULL ){

  if( !is.null(path) && !file.exists(path))
    stop("could not find file ", shQuote(path), call. = FALSE)

  if( is.null(path) )
    path <- system.file(package = "officer", "template/template.docx")

  package_dir <- tempfile()
  unpack_folder( file = path, folder = package_dir )

  obj <- structure(list( package_dir = package_dir ),
                   .Names = c("package_dir"),
                   class = "rdocx")

  obj$doc_properties <- read_core_properties(package_dir)
  obj$content_type <- content_type$new( package_dir )
  obj$doc_obj <- docx_part$new(package_dir,
                               main_file = "document.xml",
                               cursor = "/w:document/w:body/*[1]",
                               body_xpath = "/w:document/w:body")
  obj$styles <- read_docx_styles(package_dir)

  header_files <- list.files(file.path(package_dir, "word"),
                             pattern = "^header[0-9]*.xml$")
  headers <- lapply(header_files, function(x){
    docx_part$new(path = package_dir, main_file = x, cursor = "/w:hdr/*[1]", body_xpath = "/w:hdr")
  })
  names(headers) <- header_files
  obj$headers <- headers

  footer_files <- list.files(file.path(package_dir, "word"),
                             pattern = "^footer[0-9]*.xml$")
  footers <- lapply(footer_files, function(x){
    docx_part$new(path = package_dir, main_file = x, cursor = "/w:ftr/*[1]", body_xpath = "/w:ftr")
  })
  names(footers) <- footer_files
  obj$footers <- footers

  if( !file.exists(file.path(package_dir, "word", "footnotes.xml")) ){
    file.copy(system.file(package = "officer", "template", "footnotes.xml"),
              file.path(package_dir, "word", "footnotes.xml")
              )
    obj$content_type$add_override(
      setNames("application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml", "/word/footnotes.xml" )
    )
  }

  obj$footnotes <- docx_part$new(
    package_dir, main_file = "footnotes.xml",
    cursor = "/w:footnotes/*[last()]", body_xpath = "/w:footnotes"
  )

  default_refs <- obj$styles[obj$styles$is_default,]
  obj$default_styles <- setNames( as.list(default_refs$style_name), default_refs$style_type )

  last_sect <- xml_find_first(obj$doc_obj$get(), "/w:document/w:body/w:sectPr[last()]")
  obj$sect_dim <- section_dimensions(last_sect)

  obj <- cursor_end(obj)
  obj
}

#' @export
#' @param target path to the docx file to write
#' @param ... unused
#' @rdname read_docx
#' @examples
#' print(read_docx())
#' # write a rdocx object in a docx file ----
#' if( require(magrittr) ){
#'   read_docx() %>% print(target = tempfile(fileext = ".docx"))
#' }
#'
#' @importFrom xml2 xml_attr<- xml_find_all xml_find_all
print.rdocx <- function(x, target = NULL, ...){

  if( is.null( target) ){
    cat("rdocx document with", length(x), "element(s)\n")
    cat("\n* styles:\n")

    style_names <- styles_info(x)
    style_sample <- style_names$style_type
    names(style_sample) <- style_names$style_name
    print(style_sample)


    cursor_elt <- x$doc_obj$get_at_cursor()
    cat("\n* Content at cursor location:\n")
    print(node_content(cursor_elt, x))
    return(invisible())
  }

  if( !grepl(x = target, pattern = "\\.(docx)$", ignore.case = TRUE) )
    stop(target , " should have '.docx' extension.")

  int_id <- 1 # unique id identifier

  # make all id unique for document
  all_uid <- xml_find_all(x$doc_obj$get(), "//*[@id]")
  for(z in seq_along(all_uid) ){
    xml_attr(all_uid[[z]], "id") <- int_id
    int_id <- int_id + 1
  }
  # make all id unique for footnote
  all_uid <- xml_find_all(x$footnotes$get(), "//*[@id]")
  for(z in seq_along(all_uid) ){
    xml_attr(all_uid[[z]], "id") <- int_id
    int_id <- int_id + 1
  }
  # make all id unique for headers
  for(docpart in x[["headers"]]){
    all_uid <- xml_find_all(docpart$get(), "//*[@id]")
    for(z in seq_along(all_uid) ){
      xml_attr(all_uid[[z]], "id") <- int_id
      int_id <- int_id + 1
    }
  }
  # make all id unique for footers
  for(docpart in x[["footers"]]){
    all_uid <- xml_find_all(docpart$get(), "//*[@id]")
    for(z in seq_along(all_uid) ){
      xml_attr(all_uid[[z]], "id") <- int_id
      int_id <- int_id + 1
    }
  }

  all_uid <- xml_find_all(x$footnotes$get(), "//*[@id]")
  for(z in seq_along(all_uid) ){
    xml_attr(all_uid[[z]], "id") <- int_id
    int_id <- int_id + 1
  }

  sections_ <- xml_find_all(x$doc_obj$get(), "//w:sectPr")
  last_sect <- sections_[length(sections_)]
  if( inherits( xml_find_first(x$doc_obj$get(), file.path( xml_path(last_sect), "w:type")), "xml_missing" ) ){
    xml_add_child( last_sect,
      as_xml_document("<w:type xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" w:val=\"continuous\"/>")
      )
  }

  for(header in x$headers){
    header$save()
  }

  for(footer in x$footers){
    footer$save()
  }

  x <- process_sections(x)
  x$doc_obj$save()
  x$content_type$save()
  x$footnotes$save()

  # save doc properties
  x$doc_properties['modified','value'] <- format( Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
  x$doc_properties['lastModifiedBy','value'] <- Sys.getenv("USER")
  write_core_properties(x$doc_properties, x$package_dir)
  pack_folder(folder = x$package_dir, target = target )
}

#' @export
#' @examples
#' # how many elements are there in the document ----
#' length( read_docx() )
#'
#' @importFrom xml2 read_xml xml_length xml_find_first xml_child
#' @rdname read_docx
length.rdocx <- function( x ){
  length(xml_child(x$doc_obj$get(), "w:body"))
}

#' @export
#' @title read Word styles
#' @description read Word styles and get results in
#' a tidy data.frame.
#' @param x an rdocx object
#' @examples
#' library(magrittr)
#' read_docx() %>% styles_info()
styles_info <- function( x ){
  x$styles
}

#' @export
#' @title read document properties
#' @description read Word or PowerPoint document properties
#' and get results in a data.frame.
#' @param x an \code{rdocx} or \code{rpptx} object
#' @examples
#' library(magrittr)
#' read_docx() %>% doc_properties()
doc_properties <- function( x ){
  if( inherits(x, "rdocx"))
    cp <- x$doc_properties
  else if( inherits(x, "rpptx") || inherits(x, "rxlsx") ) cp <- x$core_properties
  else stop("x should be a rpptx or a rdocx or a rxlsx object.")

  out <- data.frame(tag = cp[, 'name'], value = cp[, 'value'], stringsAsFactors = FALSE)
  row.names(out) <- NULL
  out
}

#' @export
#' @title set document properties
#' @description set Word or PowerPoint document properties. These are not visible
#' in the document but are available as metadata of the document.
#' @note
#' The "last modified" and "last modified by" fields will be automatically be updated
#' when the file is written.
#' @param x an rdocx or rpptx object
#' @param title,subject,creator,description text fields
#' @param created a date object
#' @examples
#' library(magrittr)
#' read_docx() %>% set_doc_properties(title = "title",
#'   subject = "document subject", creator = "Me me me",
#'   description = "this document is empty",
#'   created = Sys.time()) %>% doc_properties()
set_doc_properties <- function( x, title = NULL, subject = NULL,
                                creator = NULL, description = NULL, created = NULL ){

  if( inherits(x, "rdocx"))
    cp <- x$doc_properties
  else if( inherits(x, "rpptx")) cp <- x$core_properties
  else stop("x should be a rpptx or rdocx object.")

  if( !is.null(title) ) cp['title','value'] <- title
  if( !is.null(subject) ) cp['subject','value'] <- subject
  if( !is.null(creator) ) cp['creator','value'] <- creator
  if( !is.null(description) ) cp['description','value'] <- description
  if( !is.null(created) ) cp['created','value'] <- format( created, "%Y-%m-%dT%H:%M:%SZ")

  if( inherits(x, "rdocx"))
    x$doc_properties <- cp
  else x$core_properties <- cp

  x
}


#' @export
#' @title Word page layout
#' @description get page width, page height and margins (in inches). The return values
#' are those corresponding to the section where the cursor is.
#' @param x an \code{rdocx} object
#' @examples
#' docx_dim(read_docx())
docx_dim <- function(x){
  cursor_elt <- x$doc_obj$get_at_cursor()
  xpath_ <- paste0(
    file.path( xml_path(cursor_elt), "following-sibling::w:sectPr"),
    "|",
    file.path( xml_path(cursor_elt), "following-sibling::w:p/w:pPr/w:sectPr")
  )

  next_section <- xml_find_first(x$doc_obj$get(), xpath_)
  sd <- section_dimensions(next_section)
  sd$page <- sd$page / (20*72)
  sd$margins <- sd$margins / (20*72)
  sd

}


#' @export
#' @title List Word bookmarks
#' @description List bookmarks id that can be found in an \code{rdocx}
#' object.
#' @param x an \code{rdocx} object
#' @examples
#' library(magrittr)
#'
#' doc <- read_docx() %>%
#'   body_add_par("centered text", style = "centered") %>%
#'   body_bookmark("text_to_replace") %>% body_add_par("centered text", style = "centered") %>%
#'   body_bookmark("text_to_replace2")
#'
#' docx_bookmarks(doc)
#'
#' docx_bookmarks(read_docx())
docx_bookmarks <- function(x){
  stopifnot(inherits(x, "rdocx"))

  doc_ <- xml_find_all(x$doc_obj$get(), "//w:bookmarkStart[@w:name]")
  setdiff(xml_attr(doc_, "name"), "_GoBack")
}

#' @export
#' @title replace paragraphs styles
#' @description Replace styles with others in a Word document.
#' @param x an rdocx object
#' @param mapstyles a named list, names are the replacement style,
#' content (as a character vector) are the styles to be replaced.
#' @examples
#' library(magrittr)
#'
#' mapstyles <- list( "centered" = c("Normal"),
#'     "heading 3" = c("heading 1", "heading 2") )
#' doc <- read_docx() %>%
#'   body_add_par("A title", style = "heading 1") %>%
#'   body_add_par("Another title", style = "heading 2") %>%
#'   body_add_par("Hello world!", style = "Normal") %>%
#'   change_styles( mapstyles = mapstyles )
#'
#' print(doc, target = tempfile(fileext = ".docx"))
change_styles <- function( x, mapstyles ){

  if( is.null(mapstyles) || length(mapstyles) < 1 ) return(x)

  styles_table <- styles_info(x)

  from_styles <- unique( as.character( unlist(mapstyles) ) )
  to_styles <- unique( names( mapstyles) )

  if( any( is.na( mfrom <- match( from_styles, styles_table$style_name ) ) ) ){
    stop("could not find style ", paste0( shQuote(from_styles[is.na(mfrom)]), collapse = ", " ), ".", call. = FALSE)
  }
  if( any( is.na( mto <- match( to_styles, styles_table$style_name ) ) ) ){
    stop("could not find style ", paste0( shQuote(to_styles[is.na(mto)]), collapse = ", " ), ".", call. = FALSE)
  }

  mapping <- mapply(function(from, to) {
    id_to <- which( styles_table$style_type %in% "paragraph" & styles_table$style_name %in% to )
    id_to <- styles_table$style_id[id_to]

    id_from <- which( styles_table$style_type %in% "paragraph" & styles_table$style_name %in% from )
    id_from <- styles_table$style_id[id_from]

    data.frame( from = id_from, to = rep(id_to, length(from)), stringsAsFactors = FALSE )
  }, mapstyles, names(mapstyles), SIMPLIFY = FALSE)

  mapping <- do.call(rbind, mapping)
  row.names(mapping) <- NULL

  for(i in seq_len( nrow(mapping) )){
    all_nodes <- xml_find_all(x$doc_obj$get(), sprintf("//w:pStyle[@w:val='%s']", mapping$from[i]))
    xml_attr(all_nodes, "w:val") <- rep(mapping$to[i], length(all_nodes) )
  }

  x
}



#' @export
#' @title body xml document
#' @description Get the body document as xml. This function
#' is not to be used by end users, it has been implemented
#' to allow other packages to work with officer.
#' @param x an rdocx object
#' @examples
#' doc <- read_docx()
#' docx_body_xml(doc)
docx_body_xml <- function( x ){
  x$doc_obj$get()
}

#' @export
#' @title body xml document
#' @description Get the body document as xml. This function
#' is not to be used by end users, it has been implemented
#' to allow other packages to work with officer.
#' @param x an rdocx object
#' @examples
#' doc <- read_docx()
#' docx_body_relationship(doc)
docx_body_relationship <- function( x ){
  x$doc_obj$relationship()
}

