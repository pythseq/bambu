#' Function to prepare tables and genomic ranges for transript reconstruction using a txdb object
#' @title prepare annotations from txdb object or gtf file
#' @param x A \code{\link{TxDb}} object or a gtf file
#' @return A \code{\link{GRangesList}} object
#' @export
#' @examples
#'  library(TxDb.Hsapiens.UCSC.hg38.knownGene)
#'  txdb <- TxDb.Hsapiens.UCSC.hg38.knownGene
#'  prepareAnnotations(x = txdb)
#'  gtf.file <- system.file("extdata", 
#'  "Homo_sapiens.GRCh38.91_chr9_1_1000000.gtf", 
#'  package = "bambu")
#'  gr <- prepareAnnotations(x = gtf.file)
prepareAnnotations <- function(x) {
  if(is(x,"TxDb")){
    exonsByTx = exonsBy(x,by='tx', use.names=TRUE)
    if(any(duplicated(names(exonsByTx)))) {
      warning('transcript names are not unique, only one transcript per ID will be kept')
      exonsByTx <- exonsByTx[!duplicated(exonsByTx)]
    }
    
    unlistedExons <- unlist(exonsByTx, use.names = FALSE)
    partitioning <- PartitioningByEnd(cumsum(elementNROWS(exonsByTx)), names=NULL)
    txIdForReorder <- togroup(PartitioningByWidth(exonsByTx))
    unlistedExons <- unlistedExons[order(txIdForReorder, unlistedExons$exon_rank)]  #'exonsByTx' is always sorted by exon rank, not by strand, make sure that this is the case here
    unlistedExons$exon_endRank <- unlist(sapply(elementNROWS(exonsByTx),seq,to=1), use.names=FALSE)
    unlistedExons <- unlistedExons[order(txIdForReorder, start(unlistedExons))]
    mcols(unlistedExons) <- mcols(unlistedExons)[,c('exon_rank','exon_endRank')]
    exonsByTx <- relist(unlistedExons, partitioning)
    
    mcols(exonsByTx) <-  suppressMessages(AnnotationDbi::select(x, names(exonsByTx),
                                                                columns=c("TXNAME", "GENEID"),
                                                                keytype="TXNAME"))
    minEqClasses <- getMinimumEqClassByTx(exonsByTx)
    mcols(exonsByTx)$eqClass <- minEqClasses$eqClass[match(names(exonsByTx),minEqClasses$queryTxId)]
    return(exonsByTx)
  }else{
    if(grepl(".gtf",x)){
      return(prepareAnnotationsFromGTF(x))
    }
    
  }
  
  
}


#' Prepare annotation granges object from GTF file 
#' @title Prepare annotation granges object from GTF file  into a GRangesList object
#' @param file a GTF file
#' @return A \code{\link{GRangesList}} object
#' @details Unlike \code{\link{readFromGTF}}, this function finds out the equivalence classes between the transcripts,
#' with \code{\link{mcols}} data having three columns: 
#' \itemize{
#'   \item TXNAME specifying prefix for new gene Ids (genePrefix.number), defaults to empty
#'   \item GENEID indicating whether filter to remove read classes which are a subset of known transcripts(), defaults to TRUE
#'   \item eqClass specifying minimun read count to consider a read class valid in a sample, defaults to 2
#'   }
#' @noRd
prepareAnnotationsFromGTF <- function(file){
  if (missing(file)){
    stop('A GTF file is required.')
  }else{
    data <- read.delim(file,header=FALSE,comment.char='#')
    colnames(data) <- c("seqname","source","type","start","end","score","strand","frame","attribute")
    data <- data[data$type=='exon',]
    data$strand[data$strand=='.'] <- '*'
    data$GENEID = gsub('gene_id (.*?);.*','\\1',data$attribute)
    data$TXNAME=gsub('.*transcript_id (.*?);.*', '\\1',data$attribute)
    #data$exon_rank=as.integer(gsub('.*exon_number (.*?);.*', '\\1',data$attribute))
    
    geneData=unique(data[,c('TXNAME', 'GENEID')])
    grlist <- makeGRangesListFromDataFrame(
      data[,c('seqname', 'start','end','strand','TXNAME')],split.field='TXNAME',keep.extra.columns = TRUE)
    grlist <- grlist[IRanges::order(start(grlist))]
  
    unlistedExons <- unlist(grlist, use.names = FALSE)
    partitioning <- PartitioningByEnd(cumsum(elementNROWS(grlist)), names=NULL)
    txIdForReorder <- togroup(PartitioningByWidth(grlist))
    
    exon_rank <- sapply(elementNROWS(grlist), seq, from = 1)
    exon_rank[which(unlist(unique(strand(grlist)))=="-")] <- lapply(exon_rank[which(unlist(unique(strand(grlist)))=="-")], rev)  # * assumes positive for exon ranking
    names(exon_rank) <- NULL
    unlistedExons$exon_rank <- unlist(exon_rank)
    
    
    unlistedExons <- unlistedExons[order(txIdForReorder, unlistedExons$exon_rank)]  #'exonsByTx' is always sorted by exon rank, not by strand, make sure that this is the case here
    unlistedExons$exon_endRank <- unlist(sapply(elementNROWS(grlist),seq,to=1), use.names=FALSE)
    unlistedExons <- unlistedExons[order(txIdForReorder, start(unlistedExons))]
    
    
    mcols(unlistedExons) <- mcols(unlistedExons)[,c('exon_rank','exon_endRank')]
    
    grlist <- relist(unlistedExons, partitioning)
    
    # the grlist from gtf is ranked by exon_number instead of start position
    # to be consistent with prepareAnnotations
    # need to sort the grlist by start position
    
      
    minEqClasses <- getMinimumEqClassByTx(grlist)
    mcols(grlist) <- DataFrame(geneData[(match(names(grlist), geneData$TXNAME)),])
    mcols(grlist)$eqClass <- minEqClasses$eqClass[match(names(grlist),minEqClasses$queryTxId)]
  }
  return (grlist)
}




#' Get minimum equivalent class by Transcript
#' @param exonsByTranscripts exonsByTranscripts
#' @noRd
getMinimumEqClassByTx <- function(exonsByTranscripts) {

  exByTxAnnotated_singleBpStartEnd <- cutStartEndFromGrangesList(exonsByTranscripts)  # estimate overlap only based on junctions
  spliceOverlaps <- findSpliceOverlapsQuick(exByTxAnnotated_singleBpStartEnd,exByTxAnnotated_singleBpStartEnd)  ## identify transcripts which are compatible with other transcripts (subsets by splice sites)
  spliceOverlaps <- spliceOverlaps[mcols(spliceOverlaps)$compatible==TRUE,] ## select splicing compatible transcript matches

  queryTxId <- names(exByTxAnnotated_singleBpStartEnd)[queryHits(spliceOverlaps)]
  subjectTxId <- names(exByTxAnnotated_singleBpStartEnd)[subjectHits(spliceOverlaps)]
  subjectTxId <- subjectTxId[order(queryTxId, subjectTxId)]
  queryTxId <- sort(queryTxId)
  eqClass <- unstrsplit(splitAsList(subjectTxId, queryTxId), sep='.') 
  
  return( tibble(queryTxId = names(eqClass), eqClass=unname(eqClass)))
}

#' Assign New Gene with Gene Ids
#' @param exByTx exByTx
#' @param prefix prefix, defaults to empty
#' @param minoverlap defaults to 5
#' @param ignore.strand defaults to FALSE
#' @noRd
assignNewGeneIds <- function(exByTx, prefix='', minoverlap=5, ignore.strand=FALSE){
  if(is.null(names(exByTx))){
    names(exByTx) <- 1:length(exByTx)
  }

  exonSelfOverlaps <- findOverlaps(exByTx,
                                   exByTx,
                                   select='all',
                                   minoverlap=minoverlap,
                                   ignore.strand=ignore.strand)
  hitObject <- tbl_df(exonSelfOverlaps) %>% arrange(queryHits, subjectHits)
  candidateList <- hitObject %>%
    group_by(queryHits) %>%
    filter(queryHits <= min(subjectHits), queryHits != subjectHits) %>%
    ungroup()

  filteredOverlapList <- hitObject %>% filter(queryHits < subjectHits)

  rm(list=c('exonSelfOverlaps','hitObject'))
  gc(verbose = FALSE)
  length_tmp = 1
  while(nrow(candidateList) > length_tmp) {  # loop to include overlapping read classes which are not in order
    length_tmp <- nrow(candidateList)
    temp <- left_join(candidateList, filteredOverlapList, by=c("subjectHits"="queryHits")) %>%
      group_by(queryHits) %>%
      filter(! subjectHits.y %in% subjectHits, !is.na(subjectHits.y)) %>%
      ungroup %>%
      dplyr::select(queryHits, subjectHits.y) %>%
      distinct() %>%
      dplyr::rename(subjectHits=subjectHits.y)

    candidateList <- rbind(temp, candidateList)
    while(nrow(temp)>0) {
      ## annotated transcripts from unknown genes by new gene id
      temp= left_join(candidateList,filteredOverlapList,by=c("subjectHits"="queryHits")) %>%
        group_by(queryHits) %>%
        filter(! subjectHits.y %in% subjectHits, !is.na(subjectHits.y)) %>%
        ungroup %>%
        dplyr::select(queryHits,subjectHits.y) %>%
        distinct() %>%
        dplyr::rename(subjectHits=subjectHits.y)

      candidateList <- rbind(temp, candidateList)
    }
    ## second loop
    tst <- candidateList %>%
      group_by(subjectHits) %>%
      mutate(subjectCount = n()) %>%
      group_by(queryHits) %>%
      filter(max(subjectCount)>1) %>%
      ungroup()

    temp2 <- inner_join(tst, tst, by=c("subjectHits"="subjectHits")) %>%
      filter(queryHits.x!=queryHits.y)  %>%
      mutate(queryHits = if_else(queryHits.x > queryHits.y, queryHits.y, queryHits.x),
             subjectHits = if_else(queryHits.x > queryHits.y, queryHits.x, queryHits.y)) %>%
      dplyr::select(queryHits,subjectHits) %>%
      distinct()
    candidateList <-  distinct(rbind(temp2, candidateList))
  }

  candidateList <- candidateList %>%
    filter(! queryHits %in% subjectHits) %>%
    arrange(queryHits, subjectHits)
  idToAdd <- (which(!(1:length(exByTx) %in% unique(candidateList$subjectHits))))

  candidateList <- rbind(candidateList, tibble(queryHits=idToAdd, subjectHits=idToAdd)) %>%
    arrange(queryHits, subjectHits) %>%
    mutate(geneId = paste('gene', prefix, '.', queryHits, sep='')) %>%
    dplyr::select(subjectHits, geneId)
  candidateList$readClassId <- names(exByTx)[candidateList$subjectHits]

  candidateList <- dplyr::select(candidateList, readClassId, geneId)
  return(candidateList)
}


#' Calculate distance from read class to annotation
#' @param exByTx exByTx
#' @param exByTxRef exByTxRef
#' @param maxDist defaults to 35
#' @param primarySecondaryDist defaults to 5
#' @param ignore.strand defaults to FALSE
#' @noRd
calculateDistToAnnotation <- function(exByTx, exByTxRef, maxDist = 35, primarySecondaryDist = 5, ignore.strand=FALSE) {

  ########## TODO: go through filter rules: (are these correct/up to date?)
  ## (1) select minimum distance match (note: allow for a few base pairs error?)
  ## (2) select hits within (minimum unique query sequence, no start match)
  ## (3) select hits with minimum unqiue start sequence/end sequence


  #(1)  find overlaps of read classes with annotated transcripts, allow for maxDist [b] distance for each exon; exons with size less than 35bp are dropped to find overlaps, but counted towards distance and compatibility
  spliceOverlaps <- findSpliceOverlapsByDist(exByTx,
                                             exByTxRef,
                                             maxDist=maxDist,
                                             firstLastSeparate=TRUE,
                                             dropRangesByMinLength=TRUE,
                                             cutStartEnd=TRUE,
                                             ignore.strand=ignore.strand)

  txToAnTable <- tbl_df(spliceOverlaps) %>%
    group_by(queryHits)  %>%
    mutate(dist = uniqueLengthQuery + uniqueLengthSubject) %>%
    mutate(txNumber = n())

  # first round of filtering should only exclude obvious mismatches
  txToAnTableFiltered <- txToAnTable %>%
    group_by(queryHits)  %>%
    arrange(queryHits, dist) %>%
    filter(dist <= (min(dist) + primarySecondaryDist)) %>%
    filter(queryElementsOutsideMaxDist + subjectElementsOutsideMaxDist == min(queryElementsOutsideMaxDist + subjectElementsOutsideMaxDist)) %>%
    filter((uniqueStartLengthQuery <= primarySecondaryDist & uniqueEndLengthQuery <= primarySecondaryDist) == max(uniqueStartLengthQuery <= primarySecondaryDist & uniqueEndLengthQuery <= primarySecondaryDist)) %>%
    mutate(txNumberFiltered = n())

  # (2) calculate splice overlap for any not in the list (all hits have a unique new exon of at least 35bp length, might be new candidates)
  setTMP <- unique(txToAnTableFiltered$queryHits)
  spliceOverlaps_rest <- findSpliceOverlapsByDist(exByTx[-setTMP],
                                                  exByTxRef,
                                                  maxDist=0,
                                                  type='any',
                                                  firstLastSeparate=TRUE,
                                                  dropRangesByMinLength=FALSE,
                                                  cutStartEnd=TRUE,
                                                  ignore.strand=ignore.strand)

  txToAnTableRest <- tbl_df(spliceOverlaps_rest) %>%
    group_by(queryHits) %>%
    mutate(dist=uniqueLengthQuery + uniqueLengthSubject) %>%
    mutate(txNumber=n())

  txToAnTableRest$queryHits <- (1:length(exByTx))[-setTMP][txToAnTableRest$queryHits]  # reassign IDs based on unfiltered list length

  # todo: check filters, what happens to reads with only start and end match?
  txToAnTableRest <- txToAnTableRest %>%
    group_by(queryHits)  %>%
    arrange(queryHits, dist) %>%
    filter(dist <= (min(dist) + primarySecondaryDist)) %>%
    filter(queryElementsOutsideMaxDist + subjectElementsOutsideMaxDist == min(queryElementsOutsideMaxDist + subjectElementsOutsideMaxDist)) %>%
    filter((uniqueStartLengthQuery <= primarySecondaryDist & uniqueEndLengthQuery <= primarySecondaryDist) == max(uniqueStartLengthQuery <= primarySecondaryDist & uniqueEndLengthQuery <= primarySecondaryDist)) %>%
    mutate(txNumberFiltered = n())

  # (3) find overlaps for remaining reads (reads which have start/end match, this time not cut and used to calculate distance)
  setTMPRest <- unique(c(txToAnTableRest$queryHits, setTMP))
  txToAnTableRestStartEnd <- NULL
  if(length(exByTx[-setTMPRest]) > 0) {
    spliceOverlaps_restStartEnd <- findSpliceOverlapsByDist(exByTx[-setTMPRest],
                                                            exByTxRef,
                                                            maxDist=0,
                                                            type='any',
                                                            firstLastSeparate=TRUE,
                                                            dropRangesByMinLength=FALSE,
                                                            cutStartEnd=FALSE,
                                                            ignore.strand=ignore.strand)
    if(length(spliceOverlaps_restStartEnd)>0){
      txToAnTableRestStartEnd <- tbl_df(spliceOverlaps_restStartEnd) %>%
        group_by(queryHits) %>%
        mutate(dist = uniqueLengthQuery + uniqueLengthSubject + uniqueStartLengthQuery + uniqueEndLengthQuery) %>%
        mutate(txNumber = n())
      
      txToAnTableRestStartEnd$queryHits <- (1:length(exByTx))[-setTMPRest][txToAnTableRestStartEnd$queryHits]  # reassign IDs based on unfiltered list length
      
      # todo: check filters, what happens to reads with only start and end match?
      txToAnTableRestStartEnd <- txToAnTableRestStartEnd %>%
        group_by(queryHits) %>%
        arrange(queryHits, dist) %>%
        filter(dist <= (min(dist) + primarySecondaryDist)) %>%
        mutate(txNumberFiltered = n())
    }
  }
  
  txToAnTableFiltered <- rbind(txToAnTableFiltered, txToAnTableRest, txToAnTableRestStartEnd) %>% ungroup()

  txToAnTableFiltered$readClassId <- names(exByTx)[txToAnTableFiltered$queryHits]
  txToAnTableFiltered$annotationTxId <- names(exByTxRef)[txToAnTableFiltered$subjectHits]

  return(txToAnTableFiltered)
}

#' Get Empty Read Class From SE
#' @param se summarizedExperiment
#' @param annotationGrangesList defaults to NULL
#' @noRd
getEmptyClassFromSE <- function(se = se, annotationGrangesList = NULL){
  distTable <- data.table(metadata(se)$distTable)[,.(readClassId, annotationTxId, readCount, GENEID)]

  # filter out multiple geneIDs mapped to the same readClass based on rowData(se)
  compatibleData <- as.data.table(as.data.frame(rowData(se)), keep.rownames = TRUE)
  setnames(compatibleData, old = c("rn","geneId"),new = c("readClassId","GENEID"))
  distTable <- distTable[compatibleData[readClassId %in% unique(distTable$readClassId),.(readClassId,GENEID)], on = c("readClassId","GENEID")]

  distTable[, eqClass:=paste(sort(unique(annotationTxId)),collapse='.'), by = list(readClassId,GENEID)]

  rcTable <- unique(distTable[,.(readClassId, GENEID, eqClass, readCount)])
  rcTable[,eqClassReadCount:=sum(readCount), by = list(eqClass, GENEID)]
  rcTable <- unique(rcTable[,.(eqClass,eqClassReadCount, GENEID)])

  eqClassCountTable <- unique(distTable[,.(annotationTxId, GENEID, eqClass)][rcTable, on = c("GENEID","eqClass")])


  setnames(eqClassCountTable, c("annotationTxId"),c("TXNAME"))
  eqClassTable <- as.data.table(mcols(annotationGrangesList)[,c('GENEID','eqClass','TXNAME')])


  eqClassCountTable <- unique(merge(eqClassCountTable,eqClassTable,all = TRUE, on = c('GENEID','eqClass','TXNAME'))) # merge should be performed on both sides
  # if there exists new isoforms from eqClassCountTable, it would not be found in eqClassTable, keep them
  eqClassCountTable[is.na(eqClassReadCount), eqClassReadCount:=0]

  ## remove empty read class where there is no shared class found
  eqClassCountTable[,sum_nobs:=sum(eqClassReadCount), by = list(GENEID, TXNAME)]

  eqClassCountTable <- unique(eqClassCountTable[sum_nobs>0,.(GENEID, eqClass, eqClassReadCount,TXNAME)])

  setnames(eqClassCountTable,old = c("TXNAME","GENEID","eqClass","eqClassReadCount") , new = c("tx_id","gene_id","read_class_id","nobs"))


  return(eqClassCountTable)

}

#' From tx ranges to gene ranges
#' @noRd
txRangesToGeneRanges <- function(exByTx, TXNAMEGENEID_Map){
  # rename names to geneIDs
  names(exByTx) <- as.data.table(TXNAMEGENEID_Map)[match(names(exByTx),TXNAME)]$GENEID

  # combine gene exon ranges and reduce overlapping ones
  unlistData <- unlist(exByTx, use.names = TRUE)
  orderUnlistData <- unlistData[order(names(unlistData))]

  orderUnlistData$exon_rank <- NULL
  orderUnlistData$exon_endRank <- NULL

  exByGene <- splitAsList(orderUnlistData, names(orderUnlistData))

  exByGene <- GenomicRanges::reduce(exByGene)

  # add exon_rank and endRank
  unlistData <- unlist(exByGene, use.names = FALSE)
  partitionDesign <- cumsum(elementNROWS(exByGene))
  partitioning <- PartitioningByEnd(partitionDesign, names=NULL)
  geneStrand <- as.character(strand(unlistData))[partitionDesign]
  exon_rank <- sapply(width((partitioning)), seq, from=1)
  exon_rank[which(geneStrand == '-')] <- lapply(exon_rank[which(geneStrand == '-')], rev)  # * assumes positive for exon ranking
  exon_endRank <- lapply(exon_rank, rev)
  unlistData$exon_rank <- unlist(exon_rank)
  unlistData$exon_endRank <- unlist(exon_endRank)
  exByGene <- relist(unlistData, partitioning)

  return(exByGene)

}




