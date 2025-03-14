# HDP-evaluate-shiny
# This shiny app is intended for experts to express their opinion by rating
# decision options against each other

library(shiny)
library(data.tree)  #tree functionality
library(mongolite)  #use Mongo for storage
library(DiagrammeR) #display the tree
library(DT)         #interface for selecting models from the DB
library(rjson)      #gives us more flexibility for storing and loading models
library(hdpr)       #core modules

source("code-eva.R")
ui <- fluidPage(
  
  titlePanel("Statement1.1"),
  tabsetPanel(
    tabPanel("Statement2.1",
             h3("Statement3.1"),
             p("Statement4.1"),
             p("Statement5.1"),
             tags$ul(
               tags$li("Statement6.1"),
               tags$li("Statement7.1"),
               tags$li("Statement8.1"),
               tags$li("Statement9.1")
             ),
             actionButton("btnLoadFromQueryString", "Statement10.1")
    ),
    # Show a plot of the generated distribution
    tabPanel("Statement11.1",
             h4("Statement12.1"),
             fluidRow(
               column(4, uiOutput("uiEvaluateCriteria")),
               column(8,
                      actionButton("btnSaveAndCalculate", "Statement13.1"),
                      uiOutput("uiMessages"),
                      grVizOutput("modelTree")
               )
             )
    )
  )
)

server <- function(input, output, session) {
  
  hdp=reactiveValues(tree=NULL, alternatives=NULL, evaluationId=NULL,
                     expertId=NULL, modelId=NULL) #hdpr package
  
  
  dataUri <- "mongodb://localhost/hdp" #local db
  #dataUri <- "mongodb://hdpdb/hdp" #when using docker use this
  
  #Load the form from the query string
  observeEvent(input$btnLoadFromQueryString, {
    query <- getQueryString()
    queryText <- paste(names(query), query,
                       sep = "=", collapse=", ")
    
    #variables from the query string
    requestedModelId <- query[["modelId"]]
    currentExpert <- query[["expertId"]]
    
    #get the tree
    tree <- getExpertResultsAsTreeFromDb(requestedModelId, currentExpert, dataUri) #hdpr package
    if(is.null(tree)) {
      tree <- getModelAsTreeWithAlternativesFromDb(requestedModelId, dataUri) #hdpr package
    }
    
    ui.evaluation.build.byTree(tree)
    
    ui.expertTab.observer.add()
    
    hdp$tree <- tree
    hdp$alternatives <- NULL# alternatives
    hdp$expertId <- currentExpert
    hdp$modelId <- requestedModelId
    
    print("-----------StRT")
    
    #Prune(hdp$tree, fiterFun = isNotLeaf)
    ui.tree.render(hdp$tree)
  })
  
  ################################################
  # Get form values, calculate & save
  ###############################################
  
  #generate the combo frames so I can save them for later
  expert.comboFrames.generate <- function(currentNode) {
    parent <- currentNode$parent
    #get unique combinations
    combos <- getUniqueChildCombinations(parent, NULL) #hdpr package
    #put the combinations into frames
    comboFrames <- comboFrames.buildFromNodeSliders(combos, parent) #line 169
    comboFrames
  }
  
  #get the value of a slider based on the node
  slider.get <- function(node) {
    combos <- getUniqueChildCombinations(node, NULL)
    nodeSliderValues <- lapply(1:nrow(combos), function(i) {
      input[[paste0("slider_",node$name,"_",i)]]
    })
    #print("nodeliders")
    #print(unlist(nodeSliderValues))
    unlist(nodeSliderValues)
  }
  
  #when the button is clicked, calculate and save everything
  observeEvent(input$btnSaveAndCalculate, {
    #run the calculations across nodes in the tree
    
    #used to reload the form with values later if we need to
    comboFrameList <- hdp$tree$Get(expert.comboFrames.generate, filterFun = isNotRoot)
    print("-------comboFrameList:")
    print(comboFrameList)
    
    #TODO delete this...
    #saveRDS(comboFrameList, "calculateHDMWeights-comboFrames.rds")
    #saveRDS(hdp$tree, "calculateHDMWeights-tree.rds")
    
    hdp$tree <- calculateHDMWeights(hdp$tree, comboFrameList) #hdm calculator code
    
    #get the raw slider values and save them so we can pre-populate the form
    hdp$tree$Do(function(node) {
      node$sliderValues <- slider.get(node)
    }, filterFun = isNotLeaf)
    
    #convert the tree to a data frame and save it to the DB
    dfTreeAsNetwork <- ToDataFrameNetwork(hdp$tree, "pathString","level","weight","norm","sliderValues","inconsistency")
    #I am not sure why I have to do this, annoying
    dfTreeAsNetwork$from <- lapply(dfTreeAsNetwork$from,getLastElementInPath)
    dfTreeAsNetwork$to <- lapply(dfTreeAsNetwork$to,getLastElementInPath)
    
    dfTreeFlatResults <- ToDataFrameTree(hdp$tree,"pathString","level","weight","norm","sliderValues","inconsistency")
    dfTreeFlatResults$pathString <- lapply(dfTreeFlatResults$pathString,getLastElementInPath)
    
    dfTreeFlatResults$levelName <- NULL
    #TODO add inconsistency to the flat results
    print(dfTreeFlatResults)
    
    
    fullJson <- paste0('{ "modelId" : "',hdp$modelId,'",
                        "expertId" : "',hdp$expertId,'",
                       "results":', toJSON(dfTreeAsNetwork),
                       ',"alternatives":',toJSON(hdp$alternatives),
                       ',"flatResults":',toJSON(dfTreeFlatResults),
                       ',"comboFrames":',toJSON(comboFrameList),
                       '}')
    saveHdmEvaluationToDb(fullJson, hdp$expertId, hdp$modelId, dataUri) #hdpr package
    
    #TODO check tree to make sure we have reasonable values for everything
    output$uiMessages <- renderUI({
      h3("Thanks for taking the evaluation! Feel free to tweak your answers or just have a nice day :)")
    })
  })
  
  #build the combo frames from the sliders
  comboFrames.buildFromNodeSliders <- function(combos, node) {
    dfCriteria <- split(combos,rep(1:nrow(combos),1))
    criteriaDfList <- lapply(1:nrow(combos), function(i) {
      dfOut <- data.frame(streOne = c(input[[paste0("slider_",node$name,"_",i)]]), streTwo = c(100 - input[[paste0("slider_",node$name,"_",i)]]))
      colnames(dfOut) <- c(dfCriteria[[i]][[1]], dfCriteria[[i]][[2]])
      return(dfOut)
    })
    criteriaDfList
  }
  
  #############################################
  # TODO clean this up...
  #############################################
  
  #TODO probably need to add level here to accomodate duplicate node names
  slider.new <- function(node) {
    print(paste0("------Slider.New: ",node$name))
    print("---slider values node:")
    print(node$sliderValues)
    combos <- getUniqueChildCombinations(node, NULL)
    rawValues <- sapply(unlist(strsplit(as.character(node$sliderValues), ",")),trim)
    print("---raw values:")
    print(rawValues)
    #TODO may need to make sure there are no spaces or special chars in the name
    sliders <- lapply(1:nrow(combos), function(i) {
      #print("--generating sliders")
      #print(rawValues[i])
      sliderValue <- 50
      sliderValue <- if(!is.null(rawValues[i])) {
        rawValues[i]
      } else {
        50
      }
      print("----sliderValue")
      print(sliderValue)
      
      fluidRow(
        column(1,
               span(combos[i,1]),
               uiOutput(paste0("uiOutputValueA_",node$name,"_",i))
        ),
        column(5,
               sliderInput(paste0("slider_",node$name,"_",i),"",
                           value = sliderValue,
                           min = 1, max = 99)
        ),
        column(1,
               span(combos[i,2]),
               uiOutput(paste0("uiOutputValueB_",node$name,"_",i))
        )
      )
    })
    
    sliders <- c(sliders, grVizOutput(paste0("treeNode_",node$name)))
  }
  
  ui.evaluation.build.byTree <- function(tree) {
    print("ui.evaluation.build.byTree")
    allNodeNames <- tree$Get(getNodeName, filterFun = isNotLeaf)
    output$uiEvaluateCriteria <- renderUI({
      sliders <- tree$Get(slider.new, filterFun = isNotLeaf)
      tabSliders <- lapply(1:length(sliders), function(i) {
        taby <- tabPanel(paste0(allNodeNames[i]), value = allNodeNames[i],sliders[i])
        taby
      })
      do.call(tabsetPanel,c(id="nodePanels",tabSliders))
    })
    #modelTree
    #add the observers
    tree$Get(ui.nodesliders.observers.add.byNode, filterFun = isNotLeaf)
    #TODO the tabPanel is input$nodePanels, need to add an observer or something
    
    #tree$Do(ui.babytree.generate, filterFun = isNotLeaf)
    #TODO can probably update style in the observer with Do...
    #tree$Do(ui.tabs.observers.add, filterFun = isNotLeaf)
  }
  
  ui.expertTab.observer.add <- function() {
    observeEvent(input$nodePanels, {
      node <- FindNode(node=hdp$tree,name = input$nodePanels)
      ui.tree.render(hdp$tree, node)
      print(paste0("--rendering tree for node: ",input$nodePanels))
    })
  }
  
  #add observers to the sliders here
  ui.nodesliders.observers.add.byNode <- function(node) {
    #tree$Get(ui.nodesliders.observers.add.byNode, filterFun = isNotLeaf)
    combos <- getUniqueChildCombinations(node, NULL)
    lapply(1:nrow(combos), function(i) {
      observeEvent(input[[paste0("slider_",node$name,"_",i)]], {
        output[[paste0("uiOutputValueA_",node$name,"_",i)]] <- renderUI({
          span(input[[paste0("slider_",node$name,"_",i)]])
        })
        output[[paste0("uiOutputValueB_",node$name,"_",i)]] <- renderUI({
          span(100 - input[[paste0("slider_",node$name,"_",i)]])
        })
      })
    })
  }
  
  #render a nice tree
  ui.tree.render <- function(tree, specialNode) {
    SetNodeStyle(tree,  style = "filled,rounded", shape = "box", fillcolor = "GreenYellow",
                 fontname = "helvetica", inherit = TRUE)
    
    if(!missing(specialNode)) {
      SetNodeStyle(specialNode,  inherit = FALSE, fillcolor = "Thistle",
                   fontcolor = "Firebrick")
      
      print("----Special Node: ")
      print(specialNode)
    }
    
    output$modelTree=renderGrViz({
      grViz(DiagrammeR::generate_dot(ToDiagrammeRGraph(tree)),engine = "dot")
    })
  }
}

# Run the application
shinyApp(ui = ui, server = server)