source("./functions.R")
library(doParallel)
library(caret)
library(reshape2)


# Optimal policy functions ------------------------------------------------

GetOptimalDecisionsForFirstSimulation <- function(covariates) {
  stopifnot(is.data.frame(covariates))
  stopifnot("V1" %in% names(covariates))
  return(as.matrix(1 + 0.5 * covariates$V1 + 0.5 * covariates$V2))
}


# Q functions  ------------------------------------------------------------

GetQfunctionValuesForFirstSimulation <- function(covariates, given.treatement, optimal.treatment) {
  linear.part <-  8 + 4 * covariates$V1 - 2 * covariates$V2 - 2 * covariates$V3
  non.linear.part <- - 25 * (optimal.treatment - given.treatement) ** 2
  return (linear.part + non.linear.part)
}


# RewardFunctions ---------------------------------------------------------

GetRewardGivenQfunctionValuesAsMeanVec <- function(q.function.values, variance=1,
                                                   only.positive=TRUE, eps=0.01) {
  raw.reward <- rnorm(NROW(q.function.values), q.function.values, variance)
  reward <-  raw.reward - min(raw.reward) + eps
  return (list(raw.reward=as.matrix(raw.reward), 
               reward=as.matrix(reward)))
}


# Get Data List -----------------------------------------------------------

GetSimulationData <- function(sample.size, number.of.covariates, add.intercept=T) {
  covariates <- matrix(runif(sample.size * number.of.covariates, min=-1, max=1),
                       ncol=number.of.covariates)
  if (isTRUE(add.intercept)) {
    covariates <- model.matrix( ~ ., as.data.frame(covariates))
  }
  treatment <- matrix(runif(sample.size, min=0, max=2), ncol=1)
  optimal.treatment <- GetOptimalDecisionsForFirstSimulation(as.data.frame(covariates))
  q.function.values <- GetQfunctionValuesForFirstSimulation(
      covariates = as.data.frame(covariates),
      given.treatement =  treatment,
      optimal.treatment = optimal.treatment)
  reward.list <- GetRewardGivenQfunctionValuesAsMeanVec(q.function.values)
  stopifnot(is.list(reward.list))
  # FIXME: Find out how to propely estimate propensity scores
  # prop.scores <- GetPropensityScores(
  #     data.frame("treatment"=treatment, "covars"=covariates),
  #     balance.formula = formula (treatment ~ . - covars..Intercept. - 1),
  #     two.step = T)
  prop.scores <- rep(1, nrow(covariates))
   return (
     c(list(covariates=as.matrix(covariates), 
            treatment=as.matrix(treatment),
            prop.scores=as.matrix(prop.scores)), 
       reward.list))
}


# Optimization routines ---------------------------------------------------

# covariates should already contain or not intercept
OptimizeParamsOfPolicyFunction <- function(obs.data, offset, policy.function, lambda,
                                           hyperparams=list(), opt.hyperparams=list()) {
  init.pars <- opt.hyperparams$init.pars
  if (isTRUE("obj.func"  %in% names(opt.hyperparams))) {
    number.of.params <- ncol(obs.data$covariates)
    lower.params.threshold <- rep(-100, number.of.params)
    upper.params.threshold <- rep(100, number.of.params)
    optimized <- GenSA(par = initial.params, fn = opt.hyperparams$obj.func,
        lower.params.threshold, upper.params.threshold,
        control=list(smooth=T, verbose=TRUE, nb.stop.improvement=1000,
                     maxit=6000, temperature = 6000),
        # additional arguments which goes directly to ObjectiveFunction
        obs.data, offset, policy.function, lambda)
    params  <- optimized$par
  } else if (isTRUE("opt.func"  %in% names(opt.hyperparams))) {
    params <- opt.hyperparams$opt.func(params=init.pars, obs.data,  
                                       offset, policy.function, lambda, 
                                       hyperparams=hyperparams,
                                       opt.hyperparams=opt.hyperparams)
  } else {
    stop("Uknown optimization technique! Please provide 'opt.func' key in hyperparams!")
  }
  return (params)
}


# Get DTR value  ----------------------------------------------------------

GetDtrValuesOnFolds <- function(folds, obs.data, offset, control.offset,  
                                policy.function, lambda, opt.hyperparams=list()) {
  dtrs <- numeric(length = 0)
  for (control.fold in folds) {
    tune.obs.data <- list(
      covariates  = as.matrix(obs.data$covariates [-control.fold, ]), 
      treatment   = as.matrix(obs.data$treatment  [-control.fold, ]),
      reward      = as.matrix(obs.data$reward     [-control.fold, ]),
      prop.scores = as.matrix(obs.data$prop.scores[-control.fold, ])
    )
    params <- OptimizeParamsOfPolicyFunction(tune.obs.data, offset,
        policy.function, lambda, opt.hyperparams)
    control.obs.data <- list(
      covariates  = as.matrix(obs.data$covariates [control.fold, ]), 
      treatment   = as.matrix(obs.data$treatment  [control.fold, ]),
      raw.reward      = as.matrix(obs.data$raw.reward [control.fold, ]),
      prop.scores = as.matrix(obs.data$prop.scores[control.fold, ])
    )
    dtr.value <- ValueFunction(params = params,  obs.data = control.obs.data,  
                               offset = control.offset, 
                               policy.function = policy.function)
    dtrs <- c(dtrs, dtr.value)
  }
  return(dtrs)
}



#  Plot decisions versus observed treatment  ------------------------------

ScaleToZeroOne <- function(data) {
  return ((data - min(data))  / (max(data) - min(data)))
}



PlotDecsionsVersusObserved <- function(obs.data, policy.function, params, offset,
                                       title="DCA decisions versus observed", highlihght=NULL){
  decision.values <- policy.function(params, obs.data$covariates)
  rewards.scaled.0.1 <- (obs.data$reward - min(obs.data$reward) ) / 
                        (max(obs.data$reward) - min(obs.data$reward))
  plot(decision.values, obs.data$treatment,
       col=rgb(1 - rewards.scaled.0.1, rewards.scaled.0.1, 0),
       pch=19, main=title,  xlim = c(0,2), xlab="Predicted treatment", 
       ylab="Observed treatment")
  abline(0, 1)  
  abline(offset, 1, col = "blue", lty = 2)  
  abline(-offset, 1, col = "blue", lty = 2)  
}



# GetSimulationInfo -------------------------------------------------------


QFunctionFirstScenario <- function(params, data, policy.function) {
  pred = pmin(pmax(policy.function(params, data$covariates), 0),2)
  optimal = GetOptimalDecisionsForFirstSimulation(as.data.frame(data$covariates))
  value = mean(GetQfunctionValuesForFirstSimulation(
               covariates = as.data.frame(data$covariates),
               given.treatement = pred,
               optimal.treatment = optimal))
  return (value)
}


GetMetricsForParams  <- function(params, datasets, offset, policy.function, lambda) {
  stat.list  <- list()
  for(data.name in names(datasets)) {
    d = datasets[[data.name]]
    for (name  in names(params)) {
      p = params[[name]] 
      
      vf = ValueFunction(params = p, obs.data = d, offset = offset,  policy.function)
      objf = ObjectiveFunction(params = p, obs.data = d, offset, policy.function, lambda)
      qf = QFunctionFirstScenario(p, d, policy.function)

      stat.list[[paste("VF", name, toupper(data.name), sep=".")]] = vf
      stat.list[[paste("OBJF", name, toupper(data.name), sep=".")]] = objf
      stat.list[[paste("Qfun", name, toupper(data.name), sep=".")]] = qf
    }
  }
return (t(as.matrix(stat.list)))
}


# QFunctionSecondScenario <- function(params, data, offset, policy.function, lambda) {
#   pred = pmin(pmax(policy.function(p, data$covariates), 0),2)
#   optimal = GetOptimalDecisionsForFirstSimulation(as.data.frame(data$covariates))
#   value = mean(GetQfunctionValuesForFirstSimulation(
#                covariates = as.data.frame(d$covariates),
#                given.treatement = pred,
#                optimal.treatment = optimal))
# }



rq.with.weights <- function (formula, tau = 0.5, data, subset, weights, na.action, 
                             method = "br", model = TRUE, contrasts = NULL, ...) 
{
  call <- match.call()
  mf <- match.call(expand.dots = FALSE)
  m <- match(c("formula", "data", "subset", "weights", "na.action"), 
             names(mf), 0)
  mf <- mf[c(1, m)]
  mf$drop.unused.levels <- TRUE
  mf[[1]] <- as.name("model.frame")
  mf <- eval.parent(mf)
  if (method == "model.frame") 
    return(mf)
  mt <- attr(mf, "terms")
  weights <- as.vector(model.weights(mf))
  Y <- model.response(mf)
  X <- model.matrix(mt, mf, contrasts)
  eps <- .Machine$double.eps^(2/3)
  Rho <- function(u, tau) u * (tau - (u < 0))
  if (length(tau) > 1) {
    print("assuming many taus!")
    if (any(tau < 0) || any(tau > 1)) 
      stop("invalid tau:  taus should be >= 0 and <= 1")
    if (any(tau == 0)) 
      tau[tau == 0] <- eps
    if (any(tau == 1)) 
      tau[tau == 1] <- 1 - eps
    coef <- matrix(0, ncol(X), length(tau))
    rho <- rep(0, length(tau))
    fitted <- resid <- matrix(0, nrow(X), length(tau))
    for (i in 1:length(tau)) {
      z <- {
        if (length(weights)) 
          rq.wfit.with.weights(X, Y, tau = tau[i], weights, method, 
                               ...)
        else rq.fit(X, Y, tau = tau[i], method, ...)
      }
      coef[, i] <- z$coefficients
      resid[, i] <- z$residuals
      rho[i] <- sum(Rho(z$residuals, tau[i]))
      fitted[, i] <- Y - z$residuals
    }
    taulabs <- paste("tau=", format(round(tau, 3)))
    dimnames(coef) <- list(dimnames(X)[[2]], taulabs)
    dimnames(resid) <- list(dimnames(X)[[1]], taulabs)
    fit <- z
    fit$coefficients <- coef
    fit$residuals <- resid
    fit$fitted.values <- fitted
    if (method == "lasso") 
      class(fit) <- c("lassorqs", "rqs")
    else if (method == "scad") 
      class(fit) <- c("scadrqs", "rqs")
    else class(fit) <- "rqs"
  }
  else {
    process <- (tau < 0 || tau > 1)
    if (tau == 0) 
      tau <- eps
    if (tau == 1) 
      tau <- 1 - eps
    fit <- {
      if (length(weights)) 
        rq.wfit.with.weights(X, Y, tau = tau, weights, method, ...)
      else rq.fit(X, Y, tau = tau, method, ...)
    }
    if (process) 
      rho <- list(x = fit$sol[1, ], y = fit$sol[3, ])
    else {
      dimnames(fit$residuals) <- list(dimnames(X)[[1]], 
                                      NULL)
      rho <- sum(Rho(fit$residuals, tau))
    }
    if (method == "lasso") 
      class(fit) <- c("lassorq", "rq")
    else if (method == "scad") 
      class(fit) <- c("scadrq", "rq")
    else class(fit) <- ifelse(process, "rq.process", "rq")
  }
  fit$na.action <- attr(mf, "na.action")
  fit$formula <- formula
  fit$terms <- mt
  fit$xlevels <- .getXlevels(mt, mf)
  fit$call <- call
  fit$tau <- tau
  fit$weights <- weights
  fit$residuals <- drop(fit$residuals)
  fit$rho <- rho
  fit$method <- method
  fit$fitted.values <- drop(fit$fitted.values)
  attr(fit, "na.message") <- attr(m, "na.message")
  if (model) 
    fit$model <- mf
  fit
}



rq.wfit.with.weights <- function (x, y, tau = 0.5, weights, method = "br", ...)  {
  if (any(weights < 0)) 
    stop("negative weights not allowed")
  if (length(tau) > 1) {
    tau <- tau[1]
    warning("Multiple taus not allowed in rq.wfit: solution restricted to first element")
  }
  contr <- attr(x, "contrasts")
  wx <- x * weights
  wy <- y * weights
  fit <- switch(method, fn = rq.fit.fnb(wx, wy, tau = tau,  ...), 
                fnb = rq.fit.fnb(wx, wy, tau = tau, ...), 
                br = rq.fit.br(wx,  wy, tau = tau, ...), 
                fnc = rq.fit.fnc(wx, wy, tau = tau, ...), 
                pfn = rq.fit.pfn(wx, wy, tau = tau, ...), { 
                  what <- paste("rq.fit.", method, sep = "") 
                    if (exists(what, mode = "function")) 
                      (get(what, mode = "function"))(wx,  wy, tau, ...) 
                    else stop(paste("unimplemented method:",  method)) 
                  })
  if (length(fit$sol)) 
    fit$fitted.values <- x %*% fit$sol[-(1:3), ]
  else fit$fitted.values <- x %*% fit$coef
  fit$residuals <- y - fit$fitted.values
  fit$contrasts <- attr(x, "contrasts")
  fit$weights <- weights
  fit
}



